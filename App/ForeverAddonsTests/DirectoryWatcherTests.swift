import Foundation
import Synchronization
import Testing

@Suite struct DirectoryWatcherTests {
    @Test func createsDirectoryAndReportsDebouncedChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DirectoryWatcherTests-\(UUID().uuidString)/installations", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let calls = Atomic<Int>(0)
        let watcher = DirectoryWatcher(url: directory, latency: .milliseconds(200)) {
            calls.add(1, ordering: .relaxed)
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))

        // An atomic write (temp file + rename), like InstallStore's, several times in a burst.
        for index in 0..<3 {
            try Data("{\"n\": \(index)}".utf8).write(to: directory.appending(path: "a.json"), options: .atomic)
        }
        try await Task.sleep(for: .milliseconds(700))
        #expect(calls.load(ordering: .relaxed) == 1)

        // Still watching after the folder is deleted and recreated.
        try FileManager.default.removeItem(at: directory)
        try await Task.sleep(for: .milliseconds(700))
        let afterDelete = calls.load(ordering: .relaxed)
        try Data("{}".utf8).write(to: directory.appending(path: "b.json"), options: .atomic)
        try await Task.sleep(for: .milliseconds(700))
        #expect(calls.load(ordering: .relaxed) > afterDelete)
    }
}
