#ifndef Glint_Bridging_Header_h
#define Glint_Bridging_Header_h

#import <Foundation/Foundation.h>

/// `-[NSAppleEventDescriptor descriptorAtIndex:]` isn't bridged to Swift on the
/// current SDK (its indexed-list access is missing from the Swift overlay), so
/// expose it via this one-line helper. Items are 1-indexed.
NSAppleEventDescriptor *glint_aeDescriptorAtIndex(NSAppleEventDescriptor *list, NSInteger index);

/// Wraps `-[NSWindow addChildWindow:ordered:]` in an ObjC `@try`/`@catch` so a
/// view service that died while its remote view was still parented to our
/// window cannot take the process down. Idempotent; called from
/// `ChildWindowExceptionGuard.install()`.
void glint_installChildWindowExceptionGuard(void);

/// Whether the swizzle above is in place. False means AppKit no longer has the
/// method, so the app is running unguarded.
BOOL glint_childWindowExceptionGuardIsInstalled(void);

#endif /* Glint_Bridging_Header_h */
