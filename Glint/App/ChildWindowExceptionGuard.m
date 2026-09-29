// The `@catch` half of ChildWindowExceptionGuard (see GlintApp.swift for what
// this is defending against and why this method is the right frame). It lives
// in ObjC for one reason: Swift cannot catch ObjC exceptions, and the raise
// happens deep inside AppKit's ordering-group broadcast.
//
// Policy stays on the Swift side — this file decides nothing, it only gives
// the exception a place to be caught and asks whether to swallow it.

#import "Glint-Bridging-Header.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "Glint-Swift.h"

static void (*glint_originalAddChildWindow)(id, SEL, NSWindow *, NSWindowOrderingMode);
static BOOL glint_guardInstalled = NO;

BOOL glint_childWindowExceptionGuardIsInstalled(void) {
    return glint_guardInstalled;
}

static void glint_guardedAddChildWindow(id self,
                                        SEL _cmd,
                                        NSWindow *child,
                                        NSWindowOrderingMode order) {
    @try {
        glint_originalAddChildWindow(self, _cmd, child, order);
    } @catch (NSException *exception) {
        if (![GlintChildWindowExceptionGuard shouldSwallowWithName:exception.name
                                                         callStack:exception.callStackSymbols]) {
            @throw;
        }
        [GlintChildWindowExceptionGuard noteSwallowedWithName:exception.name
                                                       reason:exception.reason];
    }
}

void glint_installChildWindowExceptionGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method method = class_getInstanceMethod([NSWindow class],
                                                @selector(addChildWindow:ordered:));
        // Defensive: if a future AppKit drops or renames this, the app must
        // still launch — it just runs without the guard.
        if (method == NULL) { return; }

        glint_originalAddChildWindow = (void *)method_getImplementation(method);
        method_setImplementation(method, (IMP)glint_guardedAddChildWindow);
        glint_guardInstalled = YES;
    });
}
