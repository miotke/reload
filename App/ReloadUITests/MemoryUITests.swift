import AppKit
import XCTest

/// Drives a throwaway Reload through the screens people use most, many times over, and
/// fails if that leaves leaks or memory behind (docs/development.md#ui-tests). Not run in CI:
/// `scripts/ui-tests.sh` runs it before each push. XCTest, because UI testing needs it.
final class MemoryUITests: XCTestCase {
    /// Rounds of every action after the warm-up round.
    static let rounds = Int(ProcessInfo.processInfo.environment["RELOAD_UI_ROUNDS"] ?? "") ?? 8
    /// Leaked bytes may grow this much over all rounds; anything that leaks per round
    /// passes it quickly. The constant leak in Apple's App Shortcuts connections is in both
    /// measurements, so it cancels out.
    static let leakAllowance = 16 * 1024
    /// Live heap bytes may grow this much over all rounds. AppKit and SwiftUI keep ~75 KB per
    /// round of their own bookkeeping (window KVO, glass effects); a Reload retain cycle
    /// that keeps a window's models alive costs megabytes. The footprint isn't checked: it
    /// also counts freed memory the allocator keeps, which swings by tens of MB on its own.
    static let heapAllowance = 4 * 1024 * 1024

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
        XCTAssertNotNil(ProcessInfo.processInfo.environment["RELOAD_MEASURE"], "run this through scripts/ui-tests.sh, which measures the app")

        exerciseOnce()
        let before = try Self.measure(pid, label: "before")
        var series: [String] = []
        for round in 1...Self.rounds {
            exerciseOnce()
            series.append(Self.megabytes(Double(try Self.measure(pid, label: "round-\(round)").footprint)))
        }
        print("MemoryUITests: footprint per round \(series.joined(separator: ", "))")
        let after = try Self.measure(pid, label: "after")

        let report = "leaked bytes \(before.leakedBytes) → \(after.leakedBytes), live heap \(Self.megabytes(Double(before.liveHeap))) → \(Self.megabytes(Double(after.liveHeap))), footprint \(Self.megabytes(Double(before.footprint))) → \(Self.megabytes(Double(after.footprint)))"
        print("MemoryUITests: \(report)")
        XCTAssertLessThanOrEqual(after.leakedBytes - before.leakedBytes, Self.leakAllowance, "leaks grew with use: \(report)")
        XCTAssertLessThanOrEqual(after.liveHeap - before.liveHeap, Self.heapAllowance, "live memory grew with use: \(report)")
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
        // SwiftUI's Table reaches UI testing as an outline; the sidebar is the other one.
        let table = main.outlines.matching(NSPredicate(format: "label != 'Sidebar'")).firstMatch
        let rows = table.outlineRows
        XCTAssertTrue(rows.element(boundBy: 5).waitForExistence(timeout: 10), "search found nothing")
        for _ in 0..<3 { table.scroll(byDeltaX: 0, deltaY: -1500) }
        for _ in 0..<3 { table.scroll(byDeltaX: 0, deltaY: 1500) }
        // The row elements don't take right-clicks; the name text inside does.
        let firstName = rows.element(boundBy: 0).staticTexts.firstMatch
        firstName.click()
        firstName.rightClick()
        let openWindow = app.menuItems["Open in New Window"].firstMatch
        XCTAssertTrue(openWindow.waitForExistence(timeout: 5), "no Open in New Window item")
        openWindow.click()
        waitForWindowCount(2)
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(1)
        search.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        // Window ▸ Network Activity, open and closed.
        app.menuBars.menuBarItems["Window"].click()
        let networkActivity = app.menuBars.menuItems["Network Activity"].firstMatch
        XCTAssertTrue(networkActivity.waitForExistence(timeout: 5), "no Window ▸ Network Activity")
        networkActivity.click()
        waitForWindowCount(2)
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
        // Settings ▸ General, with its Dependencies section.
        app.toolbars.buttons["General"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["dependency-policy"].firstMatch.waitForExistence(timeout: 10),
                      "no dependency policy in Settings ▸ General")
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(1)

        app.outlines.staticTexts["Installed"].firstMatch.click()
    }

    @MainActor
    private func waitForWindowCount(_ count: Int) {
        let predicate = NSPredicate(format: "count == %d", count)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.windows)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "expected \(count) window(s), have: \(app.windows.allElementsBoundByIndex.map(\.title))")
    }

    // MARK: - Measuring the app process

    /// The copy this test launched: the newest Reload process (the script refuses to run
    /// while another copy is open).
    static func processID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.miotke.Reload")
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?
            .processIdentifier
    }

    /// Leaked bytes, physical footprint and live heap bytes of `pid` (`round-N` labels: the
    /// footprint only). The test runner is sandboxed and can't examine another process, so it
    /// asks `scripts/ui-tests.sh` (watching this folder) to run `leaks`, `footprint` and
    /// `heap`, and waits for the answer.
    static func measure(_ pid: pid_t, label: String) throws -> (leakedBytes: Int, footprint: Int, liveHeap: Int) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ReloadUITests-measure", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = folder.appending(path: "\(label).result")
        try? FileManager.default.removeItem(at: result)
        try "\(pid)".write(to: folder.appending(path: "\(label).request"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let text = try? String(contentsOf: result, encoding: .utf8) {
                let parts = text.split(whereSeparator: \.isWhitespace)
                guard parts.count == 3, let leaked = Int(parts[0]), let footprint = Int(parts[1]), let live = Int(parts[2]) else {
                    throw NSError(domain: "MemoryUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected measurement: \(text)"])
                }
                return (leaked, footprint, live)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw NSError(domain: "MemoryUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "no measurement for \(label) within 3 minutes"])
    }

    static func megabytes(_ bytes: Double) -> String {
        String(format: "%.1f MB", bytes / 1024 / 1024)
    }
}
