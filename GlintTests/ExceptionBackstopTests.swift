import AppKit
import XCTest
@testable import Glint

/// Covers `ChildWindowExceptionGuard`: the classification it applies, and the
/// guard actually being installed on the real `-[NSWindow addChildWindow:ordered:]`.
///
/// The guard is only defensible while it stays narrow — a match swallows an
/// exception that would otherwise have ended the process, so a false positive
/// silently hides a real bug.
final class ExceptionBackstopTests: XCTestCase {
    /// The throwing frame from both production crashes, verbatim.
    private static let orphanedRemoteViewFrame =
        "3   ViewBridge      0x000000019e6153f0 -[NSRemoteView containingWindowWillOrderOnScreen:] + 216"

    // MARK: - Classification

    /// The crash this exists for: a view service died and left its remote view
    /// parented to our window, so ordering a popover's child window on screen
    /// raised from ViewBridge. Frames as AppKit symbolicates them.
    func testMatchesOrphanedRemoteViewFrames() {
        XCTAssertTrue(ChildWindowExceptionGuard.shouldSwallow(
            name: "NSInternalInconsistencyException",
            callStack: [
                "0   CoreFoundation  0x0000000193a0e448 __exceptionPreprocess + 176",
                "1   libobjc.A.dylib 0x000000019346c5e4 objc_exception_throw + 88",
                Self.orphanedRemoteViewFrame,
                "16  AppKit          0x00000001980fcca8 -[NSWindow addChildWindow:ordered:] + 588",
            ]
        ))
    }

    /// Stacks from the shared cache do not always symbolicate the method name,
    /// but the framework column is always there — matching on it alone still
    /// has to work.
    func testMatchesUnsymbolicatedViewBridgeFrame() {
        XCTAssertTrue(ChildWindowExceptionGuard.shouldSwallow(
            name: "NSInternalInconsistencyException",
            callStack: [
                "0   CoreFoundation  0x0000000193a0e448 __exceptionPreprocess + 176",
                "3   ViewBridge      0x000000019e6153f0 0x19e600000 + 86000",
            ]
        ))
    }

    /// An inconsistency raised by our own code must still crash: same exception
    /// name, no cross-process view plumbing anywhere on the stack.
    func testDoesNotMatchAppOwnedInconsistency() {
        XCTAssertFalse(ChildWindowExceptionGuard.shouldSwallow(
            name: "NSInternalInconsistencyException",
            callStack: [
                "0   CoreFoundation  0x0000000193a0e448 __exceptionPreprocess + 176",
                "4   Glint           0x000000010235c4d8 Glint + 820440",
                "9   AppKit          0x0000000198037800 -[NSWindow _doWindowWillBeVisibleAsSheet:] + 28",
            ]
        ))
    }

    /// The ViewBridge frames alone are not enough — a different exception type
    /// out of the same framework is not the failure we understand.
    func testDoesNotMatchOtherExceptionNames() {
        XCTAssertFalse(ChildWindowExceptionGuard.shouldSwallow(
            name: "NSRangeException",
            callStack: [Self.orphanedRemoteViewFrame]
        ))
    }

    /// No stack to judge by means no match: guessing here would trade a
    /// diagnosable crash for a silent one.
    func testDoesNotMatchEmptyCallStack() {
        XCTAssertFalse(ChildWindowExceptionGuard.shouldSwallow(
            name: "NSInternalInconsistencyException",
            callStack: []
        ))
    }

    // MARK: - Installation

    /// The classification is worthless unless the swizzle is actually in place,
    /// and an unguarded app is indistinguishable from a guarded one until the
    /// day a view service dies. The test host launches the real app, so this
    /// asserts on the shipping install path in `GlintApp.init()`.
    ///
    /// The guard's *behaviour* — an exception raised inside AppKit's
    /// ordering-group broadcast being contained instead of ending the process —
    /// cannot be exercised from Swift: unwinding an ObjC exception through a
    /// Swift frame (any `NotificationCenter` observer closure a test could
    /// register) is undefined behaviour, and the production path has no Swift
    /// frame between the raise and the `@catch`. It was verified out of process
    /// against an all-ObjC reproduction instead; see the tracker's
    /// `validation.md`.
    func testGuardIsInstalled() {
        XCTAssertTrue(
            ChildWindowExceptionGuard.isInstalled,
            "the addChildWindow guard was not installed — GlintApp.init() no longer reaches it, "
                + "or AppKit dropped -[NSWindow addChildWindow:ordered:]"
        )
    }
}
