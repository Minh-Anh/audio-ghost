import XCTest
import SwiftUI
@testable import AudioGhost

/// Renders every screen in a real hosting controller. SwiftUI type-checks at compile time but
/// still traps at runtime on things like a `Picker` whose selection type doesn't match its tags,
/// so each screen gets laid out at least once here.
@MainActor
final class UISmokeTests: XCTestCase {

    private var window: UIWindow!
    private var app: AppEnvironment!

    override func setUp() {
        super.setUp()
        app = AppEnvironment()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    private func render<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
        let controller = UIHostingController(rootView: view.environment(app))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        // Reaching here means `body` was evaluated and laid out without trapping. A non-zero
        // fitting size proves the layout produced actual content rather than an empty view.
        let fitting = controller.sizeThatFits(in: window.bounds.size)
        XCTAssertGreaterThan(fitting.width * fitting.height, 0, "view laid out empty",
                             file: file, line: line)
    }

    func testHomeRenders() {
        render(HomeView())
    }

    func testHomeRendersWithAGhost() {
        var ghost = Ghost(name: "Smoke", latitude: 43.949317, longitude: 4.805528)
        ghost.audioFileName = "x.caf"
        ghost.audioDuration = 6
        app.store.upsert(ghost)
        render(HomeView())
        app.store.delete(ghost)
    }

    func testGhostEditorRenders() {
        render(GhostEditorView(ghost: Ghost(name: "Editor", latitude: 48.8584, longitude: 2.2945)))
    }

    func testGhostEditorRendersForANewGhost() {
        render(GhostEditorView(ghost: Ghost()))
    }

    func testSessionScreenRenders() {
        render(SessionScreenView())
    }

    func testCalibrationFlowRenders() {
        render(CalibrationFlowView())
    }

    func testDebugHUDRenders() {
        render(ScrollView { DebugHUDView() })
    }

    func testDebugSimulationRenders() {
        render(NavigationStack { DebugSimulationView() })
    }

    func testTuningSheetRenders() {
        render(TuningSheet())
    }

    func testSignFlipSheetRenders() {
        render(SignFlipSheet())
    }

    func testFrameProbeRenders() {
        render(FrameProbeView())
    }
}
