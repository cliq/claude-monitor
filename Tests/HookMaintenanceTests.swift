import XCTest
@testable import ClaudeMonitor

final class HookMaintenanceTests: XCTestCase {
    // MARK: needsRefresh (the version gate)

    func test_needsRefresh_whenNoLastBuild_isTrue() {
        XCTAssertTrue(HookMaintenance.needsRefresh(currentBuild: "4", lastBuild: nil))
    }

    func test_needsRefresh_whenSameBuild_isFalse() {
        XCTAssertFalse(HookMaintenance.needsRefresh(currentBuild: "4", lastBuild: "4"))
    }

    func test_needsRefresh_whenBuildChanged_isTrue() {
        XCTAssertTrue(HookMaintenance.needsRefresh(currentBuild: "5", lastBuild: "4"))
    }

    // MARK: reinstallOutdated

    func test_reinstallOutdated_onlyReinstallsOutdatedDirs() {
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let c = URL(fileURLWithPath: "/c")
        let statuses: [String: HookInstallStatus] = ["/a": .outdated, "/b": .installed, "/c": .notInstalled]
        var installed: [URL] = []

        let refreshed = HookMaintenance.reinstallOutdated(
            managedDirs: [a, b, c],
            inspect: { statuses[$0.path]! },
            install: { installed.append($0) }
        )

        XCTAssertEqual(installed, [a], "only the .outdated dir should be reinstalled")
        XCTAssertEqual(refreshed, [a])
    }

    func test_reinstallOutdated_swallowsErrorsAndContinues() {
        struct Boom: Error {}
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        var installed: [URL] = []

        let refreshed = HookMaintenance.reinstallOutdated(
            managedDirs: [a, b],
            inspect: { _ in .outdated },
            install: { dir in if dir == a { throw Boom() }; installed.append(dir) }
        )

        XCTAssertEqual(installed, [b], "b is still processed after a throws")
        XCTAssertEqual(refreshed, [b])
    }

    func test_reinstallOutdated_emptyWhenNothingOutdated() {
        let a = URL(fileURLWithPath: "/a")
        let refreshed = HookMaintenance.reinstallOutdated(
            managedDirs: [a],
            inspect: { _ in .installed },
            install: { _ in XCTFail("should not install a current dir") }
        )
        XCTAssertTrue(refreshed.isEmpty)
    }
}
