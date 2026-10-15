import AppKit
import XCTest

/// Drives a throwaway Reload through the screens people use most, many times over, and
/// fails if that leaves leaks or memory behind (docs/development.md#ui-tests). Not run in CI:
/// `scripts/ui-tests.sh` runs it before each push. XCTest, because UI testing needs it.
final class MemoryUITests: XCTestCase {
    /// Rounds of every action after the warm-up round.
    static let rounds = 8
    /// Leaked bytes may grow this much over all rounds; anything that leaks per round
    /// passes it quickly. The constant leak in Apple's App Shortcuts connections is in both
    /// measurements, so it cancels out.
    static let leakAllowance = 16 * 1024
    /// Physical footprint may grow this much after the warm-up round (caches settling).
    static let footprintAllowance = 25.0 * 1024 * 1024

    var app: XCUIApplication!

    @MainActor
    func testUsingTheAppLeavesNoLeaksOrGrowth() async throws {
        continueAfterFailure = false
        let fixture = try await UITestFixture.make()
        defer { fixture.remove() }
        app = XCUIApplication()
        app.launchEnvironment["RELOAD_DATA_DIR"] = fixture.dataDirectory.path(percentEncoded: false)
        // A fresh main window, never the windows of another copy's last session.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the main window didn't open")
        let pid = try XCTUnwrap(Self.processID(), "couldn't find the launched app")

        exerciseOnce()
        let leaksBefore = try Self.leakedBytes(pid)
        let footprintBefore = try Self.footprint(pid)
        for _ in 0..<Self.rounds { exerciseOnce() }
        let leaksAfter = try Self.leakedBytes(pid)
        let footprintAfter = try Self.footprint(pid)

        let report = "leaked bytes \(leaksBefore) → \(leaksAfter), footprint \(Self.megabytes(footprintBefore)) → \(Self.megabytes(footprintAfter))"
        print("MemoryUITests: \(report)")
        XCTAssertLessThanOrEqual(leaksAfter - leaksBefore, Self.leakAllowance, "leaks grew with use: \(report)")
        XCTAssertLessThanOrEqual(footprintAfter - footprintBefore, Self.footprintAllowance, "memory grew with use: \(report)")
    }

    // MARK: - One round of the app

    @MainActor
    private func exerciseOnce() {
        let main = app.windows.firstMatch

        // Browse: search, scroll the results, open one in the inspector and in its own window.
        app.outlines.staticTexts["Browse"].firstMatch.click()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("Test Addon")
        let rows = main.tables.firstMatch.tableRows
        XCTAssertTrue(rows.element(boundBy: 5).waitForExistence(timeout: 10), "search found nothing")
        let table = main.tables.firstMatch
        for _ in 0..<3 { table.scroll(byDeltaX: 0, deltaY: -1500) }
        for _ in 0..<3 { table.scroll(byDeltaX: 0, deltaY: 1500) }
        rows.element(boundBy: 0).click()
        rows.element(boundBy: 0).doubleClick()
        waitForWindowCount(2)
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(1)
        search.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        // Window ▸ Network Activity, open and closed.
        app.typeKey("a", modifierFlags: [.command, .option])
        XCTAssertTrue(app.windows["Network Activity"].waitForExistence(timeout: 10))
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(1)

        // Settings ▸ Sources: turn WoWInterface off and on again (Browse re-reads the catalogue).
        app.typeKey(",", modifierFlags: .command)
        let sourcesTab = app.toolbars.buttons["Sources"].firstMatch
        XCTAssertTrue(sourcesTab.waitForExistence(timeout: 10))
        sourcesTab.click()
        let wowInterface = app.descendants(matching: .any)["source-wowinterface"].firstMatch
        XCTAssertTrue(wowInterface.waitForExistence(timeout: 10))
        wowInterface.click()
        wowInterface.click()
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(1)

        app.outlines.staticTexts["Installed"].firstMatch.click()
    }

    @MainActor
    private func waitForWindowCount(_ count: Int) {
        let predicate = NSPredicate(format: "count == %d", count)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.windows)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "expected \(count) window(s)")
    }

    // MARK: - Measuring the app process

    /// The copy this test launched: the newest Reload process (the script refuses to run
    /// while another copy is open).
    static func processID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.miotke.Reload")
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?
            .processIdentifier
    }

    /// Total leaked bytes `leaks` reports for `pid`.
    static func leakedBytes(_ pid: pid_t) throws -> Int {
        let output = try run("/usr/bin/leaks", ["\(pid)"])
        guard let match = output.firstMatch(of: /(\d+) leaks? for (\d+) total leaked bytes/),
              let bytes = Int(match.output.2) else {
            throw NSError(domain: "MemoryUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected leaks output:\n\(output)"])
        }
        return bytes
    }

    /// Physical footprint in bytes, as `footprint` reports it.
    static func footprint(_ pid: pid_t) throws -> Double {
        let output = try run("/usr/bin/footprint", ["-p", "\(pid)"])
        guard let match = output.firstMatch(of: /phys_footprint:\s+([\d.]+)\s+(KB|MB|GB)/),
              let value = Double(match.output.1) else {
            throw NSError(domain: "MemoryUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected footprint output:\n\(output)"])
        }
        let scale: Double = switch match.output.2 {
        case "KB": 1024
        case "MB": 1024 * 1024
        default: 1024 * 1024 * 1024
        }
        return value * scale
    }

    static func megabytes(_ bytes: Double) -> String {
        String(format: "%.1f MB", bytes / 1024 / 1024)
    }

    /// Runs a tool and returns its output; `leaks` exits 1 when it finds any, which is fine.
    static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
