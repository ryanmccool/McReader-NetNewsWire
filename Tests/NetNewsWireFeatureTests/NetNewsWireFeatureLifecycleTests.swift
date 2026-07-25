import XCTest
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWireFeatureLifecycleTests: XCTestCase {
    func testApplicationForegroundPreservesUpstreamOrdering() {
        var calls = [String]()
        let lifecycle = NetNewsWireFeatureApplicationLifecycle(
            resumeIfNecessary: { calls.append("resume") },
            prepareAccountsForForeground: { calls.append("prepareForeground") },
            prepareAccountsForBackground: { calls.append("prepareBackground") },
            didReceiveMemoryWarning: { calls.append("memoryWarning") }
        )

        lifecycle.applicationWillEnterForeground()

        XCTAssertEqual(calls, ["resume", "prepareForeground"])
    }

    func testSceneLifecycleOwnsOnlyCoordinatorCallbacks() {
        var calls = [String]()
        let lifecycle = NetNewsWireFeatureSceneLifecycle(
            resetFocus: { calls.append("resetFocus") },
            didEnterBackground: { calls.append("didEnterBackground") },
            suspend: { calls.append("suspend") }
        )

        lifecycle.sceneWillEnterForeground()
        lifecycle.sceneDidEnterBackground()
        lifecycle.suspend()

        XCTAssertEqual(calls, ["resetFocus", "didEnterBackground", "suspend"])
    }

    func testApplicationBackgroundAndMemoryWarningUseSharedCallbacks() {
        var calls = [String]()
        let lifecycle = NetNewsWireFeatureApplicationLifecycle(
            resumeIfNecessary: {},
            prepareAccountsForForeground: {},
            prepareAccountsForBackground: { calls.append("prepareBackground") },
            didReceiveMemoryWarning: { calls.append("memoryWarning") }
        )

        lifecycle.applicationDidEnterBackground()
        lifecycle.didReceiveMemoryWarning()

        XCTAssertEqual(calls, ["prepareBackground", "memoryWarning"])
    }
}
