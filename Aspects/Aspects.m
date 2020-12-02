//
//  Aspects.m
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import "Aspects.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define AspectLog(...)
//#define AspectLog(...) do { NSLog(__VA_ARGS__); }while(0)
#define AspectLogError(...) do { NSLog(__VA_ARGS__); }while(0)

// Block internals.
typedef NS_OPTIONS(int, AspectBlockFlags) {
	AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
	AspectBlockFlagsHasSignature          = (1 << 30)
};
typedef struct _AspectBlock {
	__unused Class isa;
	AspectBlockFlags flags;
	__unused int reserved;
	void (__unused *invoke)(struct _AspectBlock *block, ...);
	struct {
		unsigned long int reserved;
		unsigned long int size;
		// requires AspectBlockFlagsHasCopyDisposeHelpers
		void (*copy)(void *dst, const void *src);
		void (*dispose)(const void *);
		// requires AspectBlockFlagsHasSignature
		const char *signature;
		const char *layout;
	} *descriptor;
	// imported variables
} *AspectBlockRef;

//  Aspecth的环境，包含被hook的实例、调用方法和参数
//  遵守AspectInfo协议
@interface AspectInfo : NSObject <AspectInfo>
- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation;
@property (nonatomic, unsafe_unretained, readonly) id instance;
@property (nonatomic, strong, readonly) NSArray *arguments;
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

// Tracks a single aspect.
//  Aspect标识，包含一次完整Aspect的所有内容
//  内部实现了remove方法，需要使用遵守AspectToken即可
@interface AspectIdentifier : NSObject
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error;
- (BOOL)invokeWithInfo:(id<AspectInfo>)info;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, strong) id block;
@property (nonatomic, strong) NSMethodSignature *blockSignature;
@property (nonatomic, weak) id object;
@property (nonatomic, assign) AspectOptions options;
@end

// Tracks all aspects for an object/class.
//  AspectsContainer是一个对象或者类的所有的 Aspects 的容器
//  每次注入Aspects时会将其按照option里的时机放到对应数组中，方便后续的统一管理(例如移除)
@interface AspectsContainer : NSObject
- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)injectPosition;
- (BOOL)removeAspect:(id)aspect;
- (BOOL)hasAspects;
@property (atomic, copy) NSArray *beforeAspects;
@property (atomic, copy) NSArray *insteadAspects;
@property (atomic, copy) NSArray *afterAspects;
@end

// 每个类都有一个AspectTracker，用于追踪记录该类被hook的方法
@interface AspectTracker : NSObject
- (id)initWithTrackedClass:(Class)trackedClass;
@property (nonatomic, strong) Class trackedClass;
@property (nonatomic, readonly) NSString *trackedClassName;
@property (nonatomic, strong) NSMutableSet *selectorNames;
// 标记其所有子类有hook的方法 示例：[HookingSelectorName: (AspectTracker1,AspectTracker2...)]
@property (nonatomic, strong) NSMutableDictionary *selectorNamesToSubclassTrackers;
- (void)addSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (void)removeSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName;
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName;
@end

//  给NSInvocation添加分类，用来获取所有参数
@interface NSInvocation (Aspects)
- (NSArray *)aspects_arguments;
@end

#define AspectPositionFilter 0x07

#define AspectError(errorCode, errorDescription) do { \
AspectLogError(@"Aspects: %@", errorDescription); \
if (error) { *error = [NSError errorWithDomain:AspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}]; }}while(0)

NSString *const AspectErrorDomain = @"AspectErrorDomain";
static NSString *const AspectsSubclassSuffix = @"_Aspects_";
static NSString *const AspectsMessagePrefix = @"aspects_";

@implementation NSObject (Aspects)

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public Aspects API

+ (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add((id)self, selector, options, block, error);
}

/// @return A token which allows to later deregister the aspect.
- (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add(self, selector, options, block, error);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private Helper

static id aspect_add(id self, SEL selector, AspectOptions options, id block, NSError **error) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);
    NSCParameterAssert(block);

    __block AspectIdentifier *identifier = nil;
    // 加锁
    aspect_performLocked(^{
        // 判断 selector 是否可以被 hook
        if (aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            // 获取切面容器对象
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, selector);
            // 创建切面识别对象
            identifier = [AspectIdentifier identifierWithSelector:selector object:self options:options block:block error:error];
            // 创建成功
            if (identifier) {
                // 根据options对切面识别对象进行保存
                [aspectContainer addAspect:identifier withOptions:options];

                // Modify the class to allow message interception.
                // 修改这个类实现允许消息拦截
                aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}

static BOOL aspect_remove(AspectIdentifier *aspect, NSError **error) {
    NSCAssert([aspect isKindOfClass:AspectIdentifier.class], @"Must have correct type.");

    __block BOOL success = NO;
    // 加锁
    aspect_performLocked(^{
        // 切面识别对象中的保存的进行hook的对象
        id self = aspect.object; // strongify
        if (self) {
            // 根据self与方法，获取切面容器对象
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, aspect.selector);
            // 移除切面识别对象
            success = [aspectContainer removeAspect:aspect];
            // 清除hook操作创建的子类和进行方法交换的方法
            aspect_cleanupHookedClassAndSelector(self, aspect.selector);
            // destroy token
            // 销毁保存的数据
            aspect.object = nil;
            aspect.block = nil;
            aspect.selector = NULL;
        }else {
            // 进行hook的对象已经被销毁
            NSString *errrorDesc = [NSString stringWithFormat:@"Unable to deregister hook. Object already deallocated: %@", aspect];
            AspectError(AspectErrorRemoveObjectAlreadyDeallocated, errrorDesc);
        }
    });
    return success;
}

static void aspect_performLocked(dispatch_block_t block) {
    static OSSpinLock aspect_lock = OS_SPINLOCK_INIT;
    // iOS10后已经废弃，需要替换
    OSSpinLockLock(&aspect_lock);
    block();
    OSSpinLockUnlock(&aspect_lock);
}

// 创建别名方法
static SEL aspect_aliasForSelector(SEL selector) {
    NSCParameterAssert(selector);
	return NSSelectorFromString([AspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

// 将block转换为方法签名
static NSMethodSignature *aspect_blockMethodSignature(id block, NSError **error) {
    AspectBlockRef layout = (__bridge void *)block;
	if (!(layout->flags & AspectBlockFlagsHasSignature)) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't contain a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
	void *desc = layout->descriptor;
	desc += 2 * sizeof(unsigned long int);
	if (layout->flags & AspectBlockFlagsHasCopyDisposeHelpers) {
		desc += 2 * sizeof(void *);
    }
	if (!desc) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't has a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
	const char *signature = (*(const char **)desc);
	return [NSMethodSignature signatureWithObjCTypes:signature];
}

static BOOL aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    NSCParameterAssert(blockSignature);
    NSCParameterAssert(object);
    NSCParameterAssert(selector);

    // 签名匹配默认YES
    BOOL signaturesMatch = YES;
    // 获取需要hook的方法的签名
    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    // block方法的参数数量 大于 需要hook的方法的参数数量
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        // 签名匹配为NO
        signaturesMatch = NO;
    }else {
        if (blockSignature.numberOfArguments > 1) {
            // 按照作者规定，如果block有参数，则第一个必须为id<AspectInfo>,对应编码为@，
            // 如果不是则说明不是要求的block,此处会直接校验不通过
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                signaturesMatch = NO;
            }
        }
        // Argument 0 is self/block, argument 1 is SEL or id<AspectInfo>. We start comparing at argument 2.
        // The block can have less arguments than the method, that's ok.
        //  argument[0]是self/block，argument[1]是SEL/id<AspectInfo>，所以从argument[2]开始比较
        //  block的参数数量是可以少于Hook方法的参数数量，但每个位置类型必须相同
        if (signaturesMatch) {
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // Only compare parameter, not the optional type data.
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    signaturesMatch = NO; break;
                }
            }
        }
    }

    //  抛出异常
    if (!signaturesMatch) {
        NSString *description = [NSString stringWithFormat:@"Block signature %@ doesn't match %@.", blockSignature, methodSignature];
        AspectError(AspectErrorIncompatibleBlockSignature, description);
        return NO;
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class + Selector Preparation

static BOOL aspect_isMsgForwardIMP(IMP impl) {
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}

// 获取msgForward imp
static IMP aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (__unused NSException *e) {}
    }
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}

static void aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    NSCParameterAssert(selector);
    // 传入self得到其指向的类
    // 如果是类对象，则hook其forwardInvocation方法,将Container内的方法混写进去，在将class/metaClass返回
    // 如果是实例对象，则动态创建子类，返回新创建的子类
    Class klass = aspect_hookClass(self, error);
    // 从klass中获取目标方法对象
    Method targetMethod = class_getInstanceMethod(klass, selector);
    // 获取目标方法实现imps
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    // 目标方法实现不是消息转发imp
    if (!aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Make a method alias for the existing method implementation, it not already copied.
        // 目标方法类型编码
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        // 需要hook的方法的别名方法
        SEL aliasSelector = aspect_aliasForSelector(selector);
        // klass能否响应别名方法
        if (![klass instancesRespondToSelector:aliasSelector]) {
            // 给klass添加需要hook的方法的别名方法，实现指向需要hook的方法
            __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        }

        // We use forwardInvocation to hook in.
        // 替换klass的selector方法实现为MsgForward的IMP，使调用方法直接进入消息转发机制forwardInvocation
        class_replaceMethod(klass, selector, aspect_getMsgForwardIMP(self, selector), typeEncoding);
        AspectLog(@"Aspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}

// Will undo the runtime changes made.
// 清理hook的类和方法
static void aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

    // object_getClass:获得的是isa的指针
    // 当self是实例对象时，object_getClass(self) 指向其类对象
    // 当self是类对象时， object_getClass(self) 指向其元类
	Class klass = object_getClass(self);
    // klass是否是元类
    BOOL isMetaClass = class_isMetaClass(klass);
    if (isMetaClass) {
        // 如果是元类，klass为类对象
        klass = (Class)self;
    }

    // Check if the method is marked as forwarded and undo that.
    // 检查这个方法是否被替换为msgforward imp，如果是就撤销这部分操作
    // 目标方法对象
    Method targetMethod = class_getInstanceMethod(klass, selector);
    // 目标方法实现imp
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    // 目标方法实现imp == _objc_msgForward
    if (aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Restore the original method implementation.
        // 恢复为原始方法的实现
        // 类型编码
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        // 需要hook的方法的别名方法
        SEL aliasSelector = aspect_aliasForSelector(selector);
        // 根据别名方法，获取原始方法的方法实现对象
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        // 原始方法的实现imp
        IMP originalIMP = method_getImplementation(originalMethod);
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);

        // 替换klass类的selector方法的实现为原始的方法实现
        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
        AspectLog(@"Aspects: Removed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }

    // Deregister global tracked selector
    //  移除AspectTracker对应的记录(实例对象无需处理)
    aspect_deregisterTrackedSelector(self, selector);

    // Get the aspect container and check if there are any hooks remaining. Clean up if there are not.
    // 获取切面容器对象
    AspectsContainer *container = aspect_getContainerForObject(self, selector);
    if (!container.hasAspects) {
        // Destroy the container
        // 销毁self的selector的切面容器对象
        aspect_destroyContainerForObject(self, selector);

        // Figure out how the class was modified to undo the changes.
        // 获取类名
        NSString *className = NSStringFromClass(klass);
        // 如果类名尾部包含_Aspects_
        if ([className hasSuffix:AspectsSubclassSuffix]) {
            // 原始类
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:AspectsSubclassSuffix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            // 修改实例对象self的isa指针，指向originalClass
            object_setClass(self, originalClass);
            AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(originalClass));

            // We can only dispose the class pair if we can ensure that no instances exist using our subclass.
            // Since we don't globally track this, we can't ensure this - but there's also not much overhead in keeping it around.
            //objc_disposeClassPair(object.class);
        }else {
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                // hook的是类对象
                // 撤销forwardInvocation的方法交换
                aspect_undoSwizzleClassInPlace((Class)self);
            }else if (self.class != klass) {
                // hook的是KVO模式下的实例对象
                // 撤销forwardInvocation的方法交换
            	aspect_undoSwizzleClassInPlace(klass);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class

static Class aspect_hookClass(NSObject *self, NSError **error) {
    NSCParameterAssert(self);
    // self.class:当self是实例对象的时候，返回的是类对象，其他返回自身
    // object_getClass:获得的是isa的指针
    // 当self是实例对象时，self.class和object_getClass(self)相同，都是指向其类
    // 当self为类对象时，self.class是自身类，object_getClass(self)则是其元类
	Class statedClass = self.class;
	Class baseClass = object_getClass(self);
    // 类名
	NSString *className = NSStringFromClass(baseClass);

    // Already subclassed
    // 判断是否已子类化过(类后缀为_Aspects_)
	if ([className hasSuffix:AspectsSubclassSuffix]) {
		return baseClass;
        // We swizzle a class object, not a single object.
        // baseClass是元类，即self是类对象
	}else if (class_isMetaClass(baseClass)) {
        // 交互forwardInvocation方法
        return aspect_swizzleClassInPlace((Class)self);
        // Probably a KVO'ed class. Swizzle in place. Also swizzle meta classes in place.
        // statedClass！=baseClass，且不满足上述两个条件，则说明是KVO模式下的实例对象，要替换forwardInvocation方法
    }else if (statedClass != baseClass) {
        return aspect_swizzleClassInPlace(baseClass);
    }

    // Default case. Create dynamic subclass.
    // 子类类名，(类后缀为_Aspects_)
	const char *subclassName = [className stringByAppendingString:AspectsSubclassSuffix].UTF8String;
    // 根据子类类名，获取子类类对象
	Class subclass = objc_getClass(subclassName);

	if (subclass == nil) {
        // 创建新类，作为原实例对象的类的子类
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) {
            // 创建子类失败
            NSString *errrorDesc = [NSString stringWithFormat:@"objc_allocateClassPair failed to allocate class %s.", subclassName];
            AspectError(AspectErrorFailedToAllocateClassPair, errrorDesc);
            return nil;
        }

        // 交互子类的forwardInvocation方法
		aspect_swizzleForwardInvocation(subclass);
        // 改写subclass的.class方法，使其返回self.class
		aspect_hookedGetClass(subclass, statedClass);
        // 改写subclass.isa的.class方法，使其返回self.class
		aspect_hookedGetClass(object_getClass(subclass), statedClass);
        // 注册子类
		objc_registerClassPair(subclass);
	}

    // 修改实例对象self的isa指针，指向subclass
	object_setClass(self, subclass);
	return subclass;
}

// 类对象交互 forwardinvation 方法
static NSString *const AspectsForwardInvocationSelectorName = @"__aspects_forwardInvocation:";
static void aspect_swizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    // If there is no method, replace will act like class_addMethod.
    // 使用 __ASPECTS_ARE_BEING_CALLED__ 替换子类的 forwardInvocation 方法实现
    // 由于子类本身并没有实现 forwardInvocation ，
    // 所以返回的 originalImplementation 将为空值，所以子类也不会生成 AspectsForwardInvocationSelectorName 这个方法
    IMP originalImplementation = class_replaceMethod(klass, @selector(forwardInvocation:), (IMP)__ASPECTS_ARE_BEING_CALLED__, "v@:@");
    if (originalImplementation) {
        class_addMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName), originalImplementation, "v@:@");
    }
    AspectLog(@"Aspects: %@ is now aspect aware.", NSStringFromClass(klass));
}

// 撤销forwardInvocation的方法交换
static void aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    // klass类的 __aspects_forwardInvocation 方法对象
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName));
    // 对象的forwardInvocation方法对象
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    // 原始方法实现
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    // 替换klass类的forwardInvocation方法实现为原始方法实现
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(klass));
}

// hook class的class方法，返回statedClass
static void aspect_hookedGetClass(Class class, Class statedClass) {
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
    // 获取class类的class方法
	Method method = class_getInstanceMethod(class, @selector(class));
    // 创建新imp，调用返回statedClass
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
    // 替换class的calss方法实现为newIMP
	class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place

static void _aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        // 交互类集合
        swizzledClasses = [NSMutableSet new];
    });
    // 加锁
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

static Class aspect_swizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    // 获取类名
    NSString *className = NSStringFromClass(klass);

    // 需要要交换的类
    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        // 如果方法交换类集合不包含类名
        if (![swizzledClasses containsObject:className]) {
            // 交换klass的forwardInvocation方法
            aspect_swizzleForwardInvocation(klass);
            // 方法交换类集合添加类名
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}

static void aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    // 获取类名
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        // 方法交换类集合包含类名
        if ([swizzledClasses containsObject:className]) {
            
            aspect_undoSwizzleForwardInvocation(klass);
            // 方法交换类集合移除类名
            [swizzledClasses removeObject:className];
        }
    });
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Invoke Point

// This is a macro so we get a cleaner stack trace.
#define aspect_invoke(aspects, info) \
for (AspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & AspectOptionAutomaticRemoval) { \
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

// This is the swizzled forwardInvocation: method.
static void __ASPECTS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    NSCParameterAssert(self);
    NSCParameterAssert(invocation);
    // 进行hook的方法
    SEL originalSelector = invocation.selector;
    // 进行hook的方法的别名方法
	SEL aliasSelector = aspect_aliasForSelector(invocation.selector);
    // 别名方法代替原方法
    invocation.selector = aliasSelector;
    // 根据别名方法 通过关联对象 获得切面容器对象
    AspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
    // 获取类对象或元类对象，别名方法对应的切面容器对象
    AspectsContainer *classContainer = aspect_getContainerForClass(object_getClass(self), aliasSelector);
    // 保存（对象或类对象）self与别名方法的调用对象
    AspectInfo *info = [[AspectInfo alloc] initWithInstance:self invocation:invocation];
    NSArray *aspectsToRemove = nil;

    // Before hooks.
    // 执行原方法之前,调用进行hook的block
    aspect_invoke(classContainer.beforeAspects, info);
    aspect_invoke(objectContainer.beforeAspects, info);

    // Instead hooks.
    BOOL respondsToAlias = YES;
    if (objectContainer.insteadAspects.count || classContainer.insteadAspects.count) {
        // 代替原方法， 调用进行hook的block
        aspect_invoke(classContainer.insteadAspects, info);
        aspect_invoke(objectContainer.insteadAspects, info);
    }else {
        // 类对象或元类，调用hook方法的目标对象类
        Class klass = object_getClass(invocation.target);
        do {
            // 目标类能否响应别名方法
            if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                // 能响应，则进行调用
                [invocation invoke];
                break;
            }
        // 直到 respondsToAlias 为YES 或者 klass 不再有父类
        }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
    }

    // After hooks.
    // 执行原方法之后,调用进行hook的block
    aspect_invoke(classContainer.afterAspects, info);
    aspect_invoke(objectContainer.afterAspects, info);

    // If no hooks are installed, call original implementation (usually to throw an exception)
    // 没有成功调用别名方法
    if (!respondsToAlias) {
        // 调用方法对象的方法改为原方法
        invocation.selector = originalSelector;
        // 获取原forwardInvocation方法
        SEL originalForwardInvocationSEL = NSSelectorFromString(AspectsForwardInvocationSelectorName);
        // 查看能否响应原forwardInvocation方法
        if ([self respondsToSelector:originalForwardInvocationSEL]) {
            // 消息转发原方法
            ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
        }else {
            // 不能响应，抛出异常
            [self doesNotRecognizeSelector:invocation.selector];
        }
    }

    // Remove any hooks that are queued for deregistration.
    // 对aspectsToRemove中的AspectIdentifier对象执行remove方法，移除hook操作
    [aspectsToRemove makeObjectsPerformSelector:@selector(remove)];
}
#undef aspect_invoke

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Container Management

// Loads or creates the aspect container.
// 加载 或者 创建 切面容器
static AspectsContainer *aspect_getContainerForObject(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    // 创建进行替换的方法的别名方法
    SEL aliasSelector = aspect_aliasForSelector(selector);
    // 通过方法关联，key为别名方法，获取本类或本对象的切面容器
    AspectsContainer *aspectContainer = objc_getAssociatedObject(self, aliasSelector);
    // 如果不存在
    if (!aspectContainer) {
        // 新建切面容器
        aspectContainer = [AspectsContainer new];
        // 通过关联方法，以别名方法为key，将切面容器与本类或本对象进行关联
        objc_setAssociatedObject(self, aliasSelector, aspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    // 返回切面容器
    return aspectContainer;
}

// 根据类与方法，获取对应的切面容器对象
static AspectsContainer *aspect_getContainerForClass(Class klass, SEL selector) {
    NSCParameterAssert(klass);
    AspectsContainer *classContainer = nil;
    do {
        // 根据类与方法，通过关联对象 获取切面容器对象
        classContainer = objc_getAssociatedObject(klass, selector);
        // 如果获取的切面容器对象，存在切面hook，则中断
        if (classContainer.hasAspects) break;
    // 沿继承者链向上
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

// 销毁切面容器对象
static void aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    // 别名方法
    SEL aliasSelector = aspect_aliasForSelector(selector);
    // 通过关联方法，销毁切面容器对象
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking

// 全局进行了hook的类的字典
static NSMutableDictionary *aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}

// 判断是否可以被hook
static BOOL aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, AspectOptions options, NSError **error) {
    static NSSet *disallowedSelectorList;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        // 创建不允许hook方法集合
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
    });

    // Check against the blacklist.
    // 要hook的方法名称
    NSString *selectorName = NSStringFromSelector(selector);
    // 检查要hook的方法是否在不允许hook方法集合中
    if ([disallowedSelectorList containsObject:selectorName]) {
        NSString *errorDescription = [NSString stringWithFormat:@"Selector %@ is blacklisted.", selectorName];
        AspectError(AspectErrorSelectorBlacklisted, errorDescription);
        return NO;
    }

    // Additional checks.
    // hook dealloc方法，options只能是before
    AspectOptions position = options&AspectPositionFilter;
    if ([selectorName isEqualToString:@"dealloc"] && position != AspectPositionBefore) {
        NSString *errorDesc = @"AspectPositionBefore is the only valid position when hooking dealloc.";
        AspectError(AspectErrorSelectorDeallocPosition, errorDesc);
        return NO;
    }

    // 判断是否有该方法实现
    if (![self respondsToSelector:selector] && ![self.class instancesRespondToSelector:selector]) {
        NSString *errorDesc = [NSString stringWithFormat:@"Unable to find selector -[%@ %@].", NSStringFromClass(self.class), selectorName];
        AspectError(AspectErrorDoesNotRespondToSelector, errorDesc);
        return NO;
    }

    // Search for the current class and the class hierarchy IF we are modifying a class object
    // 对类对象的类层级进行判断，防止一个方法被多次hook
    // object_getClass:获取self的类对象，class_isMetaClass：是否是元类
    if (class_isMetaClass(object_getClass(self))) {
        // 记录当前类
        Class klass = [self class];
        // 进行了hook的类的字典：key:class value:AspectTracker对象
        NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
        // 当前类
        Class currentClass = [self class];

        // 根据当前类获取切面追踪对象
        AspectTracker *tracker = swizzledClassesDict[currentClass];
        // 判断子类是否已经hook该方法
        if ([tracker subclassHasHookedSelectorName:selectorName]) {
            // 已经进行了hook
            // 子类切面追踪对象集合
            NSSet *subclassTracker = [tracker subclassTrackersHookingSelectorName:selectorName];
            // 通过kvc获取当前追踪的类的类名集合
            NSSet *subclassNames = [subclassTracker valueForKey:@"trackedClassName"];
            NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked subclasses: %@. A method can only be hooked once per class hierarchy.", selectorName, subclassNames];
            AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
            return NO;
        }

        // 沿着类对象的superClass指针向上寻到直到根类
        do {
            // 根据当前类获取切面追踪对象
            tracker = swizzledClassesDict[currentClass];
            // 切面追踪对象的方法名称集合是否包含需要hook的方法
            if ([tracker.selectorNames containsObject:selectorName]) {
                if (klass == currentClass) {
                    // Already modified and topmost!
                    // 已修改，且位于最上方
                    return YES;
                }
                NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(currentClass)];
                AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                return NO;
            }
        // 当前类改为父类
        } while ((currentClass = class_getSuperclass(currentClass)));

        // Add the selector as being modified.
        // 添加方法作为修改
        // 当前类
        currentClass = klass;
        // 子类切面追踪对象
        AspectTracker *subclassTracker = nil;
        do {
            // 根据当前类获取切面追踪对象
            tracker = swizzledClassesDict[currentClass];
            // 当前类没有进行hook，所以切面追踪对象为空
            if (!tracker) {
                // 根据当前类，创建切面追踪对象
                tracker = [[AspectTracker alloc] initWithTrackedClass:currentClass];
                // 保存切面追踪对象 到 记录所有被hook的Class的字典
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            // 子类切面追踪对象是否存在
            if (subclassTracker) {
                // 存在，保存子类切面追踪对象
                [tracker addSubclassTracker:subclassTracker hookingSelectorName:selectorName];
            } else {
                // 不存在，保存进hook的方法名称
                [tracker.selectorNames addObject:selectorName];
            }

            // All superclasses get marked as having a subclass that is modified.
            // 切面追踪对象改为子类切面追踪对象，目的是让其所有的父类都被标记，具有已修改的子类
            subclassTracker = tracker;
        // 当前类改为父类
        }while ((currentClass = class_getSuperclass(currentClass)));
	} else {
        // 实例对象，直接返回YES
		return YES;
	}

    return YES;
}


static void aspect_deregisterTrackedSelector(id self, SEL selector) {
    // 如果self不是类对象，则return
    if (!class_isMetaClass(object_getClass(self))) return;

    // 全局进行了hook的类的字典
    NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
    // 方法名称
    NSString *selectorName = NSStringFromSelector(selector);
    // 当前类对象
    Class currentClass = [self class];
    AspectTracker *subclassTracker = nil;
    do {
        // 根据当前类对象，获取切面追踪对象
        AspectTracker *tracker = swizzledClassesDict[currentClass];
        if (subclassTracker) {
            // 如果存在子类追踪对象，移除子类追踪对象
            [tracker removeSubclassTracker:subclassTracker hookingSelectorName:selectorName];
        } else {
            // 如果不存在子类追踪对象，从方法名称集合中移除hook的方法名称
            [tracker.selectorNames removeObject:selectorName];
        }
        // 如果方法名称集合为空 并且 selectorNamesToSubclassTrackers存在
        if (tracker.selectorNames.count == 0 && tracker.selectorNamesToSubclassTrackers) {
            // 从 swizzledClassesDict 中移除当前类
            [swizzledClassesDict removeObjectForKey:currentClass];
        }
        // 赋值作为子类追踪对象
        subclassTracker = tracker;
    // 赋值 当前类对象 为父类
    }while ((currentClass = class_getSuperclass(currentClass)));
}

@end

@implementation AspectTracker

// 初始化切面追踪对象
- (id)initWithTrackedClass:(Class)trackedClass {
    if (self = [super init]) {
        // 保存当前追踪的类
        _trackedClass = trackedClass;
        // 初始化方法名称集合
        _selectorNames = [NSMutableSet new];
        // 子类追踪hook方法名称字典：key:selectorName value:tracker set
        _selectorNamesToSubclassTrackers = [NSMutableDictionary new];
    }
    return self;
}

// 子类是否已经hook此方法
- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName {
    return self.selectorNamesToSubclassTrackers[selectorName] != nil;
}

// 根据方法名称，保存子类切面追踪对象
- (void)addSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    // 根据方法名称，获取追踪对象集合
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    // 如果集合不存在
    if (!trackerSet) {
        // 新建追踪对象集合
        trackerSet = [NSMutableSet new];
        // 根据方法名称，保存追踪对象集合
        self.selectorNamesToSubclassTrackers[selectorName] = trackerSet;
    }
    // 在追踪对象集合中，保存子类切面追踪对象
    [trackerSet addObject:subclassTracker];
}

// 根据方法名称，移除切面追踪对象
- (void)removeSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    // 根据方法名称，获取追踪对象集合
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    // 在追踪对象集合中，移除切面追踪对象
    [trackerSet removeObject:subclassTracker];
    // 如果追踪对象集合为空
    if (trackerSet.count == 0) {
        // 在子类追踪hook方法名称字典中移除此方法名称键值对
        [self.selectorNamesToSubclassTrackers removeObjectForKey:selectorName];
    }
}

// 此方法是一个并查集，传入一个selectorName，通过递归查找，找到所有包含这个selectorName的set，最后把这些set合并在一起作为返回值返回。
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName {
    // 新建hook中的子类追踪对象集合
    NSMutableSet *hookingSubclassTrackers = [NSMutableSet new];
    // 根据方法名称，获取追踪对象集合，遍历集合
    for (AspectTracker *tracker in self.selectorNamesToSubclassTrackers[selectorName]) {
        // 如果追踪对象的方法名称集合中，包含入参方法名称
        if ([tracker.selectorNames containsObject:selectorName]) {
            // 将追踪对象添加到新建的集合
            [hookingSubclassTrackers addObject:tracker];
        }
        // unionSet：hookingSubclassTrackers取并集
        // subclassTrackersHookingSelectorName：递归调用此方法
        [hookingSubclassTrackers unionSet:[tracker subclassTrackersHookingSelectorName:selectorName]];
    }
    return hookingSubclassTrackers;
}
// 当前追踪的类的类名
- (NSString *)trackedClassName {
    return NSStringFromClass(self.trackedClass);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@, trackedClass: %@, selectorNames:%@, subclass selector names: %@>", self.class, self, NSStringFromClass(self.trackedClass), self.selectorNames, self.selectorNamesToSubclassTrackers.allKeys];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSInvocation (Aspects)

@implementation NSInvocation (Aspects)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
// 根据位置，获取参数
- (id)aspect_argumentAtIndex:(NSUInteger)index {
    // index位置的参数的类型编码
	const char *argType = [self.methodSignature getArgumentTypeAtIndex:index];
	// Skip const type qualifier.
    // 跳过 const 类型限定符
	if (argType[0] == _C_CONST) argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; [self getArgument:&val atIndex:(NSInteger)index]; return @(val); } while (0)
    // strcmp(,):字符串比较，值等于0表示两个字符串相等
	if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
		__autoreleasing id returnObj;
		[self getArgument:&returnObj atIndex:(NSInteger)index];
		return returnObj;
	} else if (strcmp(argType, @encode(SEL)) == 0) {
        SEL selector = 0;
        [self getArgument:&selector atIndex:(NSInteger)index];
        return NSStringFromSelector(selector);
    } else if (strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing Class theClass = Nil;
        [self getArgument:&theClass atIndex:(NSInteger)index];
        return theClass;
        // Using this list will box the number with the appropriate constructor, instead of the generic NSValue.
	} else if (strcmp(argType, @encode(char)) == 0) {
		WRAP_AND_RETURN(char);
	} else if (strcmp(argType, @encode(int)) == 0) {
		WRAP_AND_RETURN(int);
	} else if (strcmp(argType, @encode(short)) == 0) {
		WRAP_AND_RETURN(short);
	} else if (strcmp(argType, @encode(long)) == 0) {
		WRAP_AND_RETURN(long);
	} else if (strcmp(argType, @encode(long long)) == 0) {
		WRAP_AND_RETURN(long long);
	} else if (strcmp(argType, @encode(unsigned char)) == 0) {
		WRAP_AND_RETURN(unsigned char);
	} else if (strcmp(argType, @encode(unsigned int)) == 0) {
		WRAP_AND_RETURN(unsigned int);
	} else if (strcmp(argType, @encode(unsigned short)) == 0) {
		WRAP_AND_RETURN(unsigned short);
	} else if (strcmp(argType, @encode(unsigned long)) == 0) {
		WRAP_AND_RETURN(unsigned long);
	} else if (strcmp(argType, @encode(unsigned long long)) == 0) {
		WRAP_AND_RETURN(unsigned long long);
	} else if (strcmp(argType, @encode(float)) == 0) {
		WRAP_AND_RETURN(float);
	} else if (strcmp(argType, @encode(double)) == 0) {
		WRAP_AND_RETURN(double);
	} else if (strcmp(argType, @encode(BOOL)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(bool)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(char *)) == 0) {
		WRAP_AND_RETURN(const char *);
	} else if (strcmp(argType, @encode(void (^)(void))) == 0) {
		__unsafe_unretained id block = nil;
		[self getArgument:&block atIndex:(NSInteger)index];
		return [block copy];
	} else {
		NSUInteger valueSize = 0;
		NSGetSizeAndAlignment(argType, &valueSize, NULL);

		unsigned char valueBytes[valueSize];
		[self getArgument:valueBytes atIndex:(NSInteger)index];

		return [NSValue valueWithBytes:valueBytes objCType:argType];
	}
	return nil;
#undef WRAP_AND_RETURN
}

// 获取参数组成的数组
- (NSArray *)aspects_arguments {
	NSMutableArray *argumentsArray = [NSMutableArray array];
	for (NSUInteger idx = 2; idx < self.methodSignature.numberOfArguments; idx++) {
		[argumentsArray addObject:[self aspect_argumentAtIndex:idx] ?: NSNull.null];
	}
	return [argumentsArray copy];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectIdentifier

@implementation AspectIdentifier

+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error {
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    //  将block转换成方法签名
    NSMethodSignature *blockSignature = aspect_blockMethodSignature(block, error); // TODO: check signature compatibility, etc.
    //  判断block的参数个数和参数类型 是否兼容 要Hook的方法
    if (!aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }

    AspectIdentifier *identifier = nil;
    // block签名存在
    if (blockSignature) {
        // 新建切面识别对象
        identifier = [AspectIdentifier new];
        // 保存传递的参数与block签名
        identifier.selector = selector;
        identifier.block = block;
        identifier.blockSignature = blockSignature;
        identifier.options = options;
        identifier.object = object; // weak
    }
    // 返回切面识别对象
    return identifier;
}


// 调用block
- (BOOL)invokeWithInfo:(id<AspectInfo>)info {
    // 通过block的方法签名生成对应的调用对象
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    // 被hook的原方法调用对象
    NSInvocation *originalInvocation = info.originalInvocation;
    // block的参数数量
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;

    // Be extra paranoid. We already check that on hook registration.
    //  检查参数数量(在上面的方法，生成AspectIdentifier时，已经校验过，这里是一个额外的检验)
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        AspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }

    // The `self` of the block will be the AspectInfo. Optional.
    //  按照约定，如果block有参数，0位置的参数是Block本身，1位置的参数为AspectInfo，之后才是方法的参数
    //  没有参数则无需处理
    if (numberOfArguments > 1) {
        [blockInvocation setArgument:&info atIndex:1];
    }
    
	void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        // 参数类型
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
        // 参数所需空间大小
		NSUInteger argSize;
        // 获得编码类型的实际大小和对齐的大小
		NSGetSizeAndAlignment(type, &argSize, NULL);
        
        // 创建argSize大小的空间
		if (!(argBuf = reallocf(argBuf, argSize))) {
            AspectLogError(@"Failed to allocate memory for block invocation.");
			return NO;
		}
        
        // 获取到指向对应参数的指针
		[originalInvocation getArgument:argBuf atIndex:idx];
        // 把指向对应实参指针的地址（相当于指向实参指针的指针）传给invocation 进行拷贝，得到的就是指向实参对象的指针
		[blockInvocation setArgument:argBuf atIndex:idx];
    }
    
    //  触发block调用
    [blockInvocation invokeWithTarget:self.block];
    
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

// 移除hook
- (BOOL)remove {
    return aspect_remove(self, NULL);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectsContainer

@implementation AspectsContainer

- (BOOL)hasAspects {
    return self.beforeAspects.count > 0 || self.insteadAspects.count > 0 || self.afterAspects.count > 0;
}

// 根据options，保存切面识别对象到不同的数组中
- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)options {
    NSParameterAssert(aspect);
    NSUInteger position = options&AspectPositionFilter;
    switch (position) {
        case AspectPositionBefore:  self.beforeAspects  = [(self.beforeAspects ?:@[]) arrayByAddingObject:aspect]; break;
        case AspectPositionInstead: self.insteadAspects = [(self.insteadAspects?:@[]) arrayByAddingObject:aspect]; break;
        case AspectPositionAfter:   self.afterAspects   = [(self.afterAspects  ?:@[]) arrayByAddingObject:aspect]; break;
    }
}

// 移除切面识别对象
- (BOOL)removeAspect:(id)aspect {
    for (NSString *aspectArrayName in @[NSStringFromSelector(@selector(beforeAspects)),
                                        NSStringFromSelector(@selector(insteadAspects)),
                                        NSStringFromSelector(@selector(afterAspects))]) {
        // 通过kvc，获取保存切面识别对象的数组
        NSArray *array = [self valueForKey:aspectArrayName];
        // 获取切面识别对象的位置
        NSUInteger index = [array indexOfObjectIdenticalTo:aspect];
        if (array && index != NSNotFound) {
            // 新建数组
            NSMutableArray *newArray = [NSMutableArray arrayWithArray:array];
            // 移除切面识别对象
            [newArray removeObjectAtIndex:index];
            // 通过kvc，重新设置切面识别对象的数组
            [self setValue:newArray forKey:aspectArrayName];
            return YES;
        }
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, before:%@, instead:%@, after:%@>", self.class, self, self.beforeAspects, self.insteadAspects, self.afterAspects];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectInfo

@implementation AspectInfo

@synthesize arguments = _arguments;

- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation {
    NSCParameterAssert(instance);
    NSCParameterAssert(invocation);
    if (self = [super init]) {
        // 保存被hook的对象与原始调用对象
        _instance = instance;
        _originalInvocation = invocation;
    }
    return self;
}

// 获取原始调用对象的参数组成的数组
- (NSArray *)arguments {
    // Lazily evaluate arguments, boxing is expensive.
    if (!_arguments) {
        _arguments = self.originalInvocation.aspects_arguments;
    }
    return _arguments;
}

@end
