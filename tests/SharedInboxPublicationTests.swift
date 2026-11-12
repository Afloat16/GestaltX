import Foundation
import Darwin

// run_shared_publication.py supplies an entry point extracted from the actual
// share controller, so these same tests run against its original and new paths.
@main struct SharedInboxPublicationTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor static func run(_ name: String) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-publish-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let good = try SharedPlistInbox(container: root.appendingPathComponent("good"), namespace: "app")
        let later = try SharedPlistInbox(container: root.appendingPathComponent("later"), namespace: "app")
        let bad = try SharedPlistInbox(container: root.appendingPathComponent("bad"), namespace: "app")
        let bad2 = try SharedPlistInbox(container: root.appendingPathComponent("bad2"), namespace: "app")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["value": 42]], format: .binary, options: 0)
        let sentinel = Data("Preserve the damaged inbox path".utf8)
        for inbox in [bad, bad2] {
            try fm.createDirectory(at: inbox.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sentinel.write(to: inbox.directory)
        }
        switch name {
        case "bad-first", "two-bad", "linked-first":
            if name == "linked-first" {
                try fm.removeItem(at: bad.directory)
                try fm.createSymbolicLink(at: bad.directory, withDestinationURL: good.directory)
            }
            let inboxes = name == "two-bad" ? [bad, bad2, good, later] : [bad, good, later]
            do { try publishShareFixture(bytes, name: "source.plist", inboxes: inboxes) }
            catch { throw Failure(message: "A healthy signed inbox must receive the shared document: \(error)") }
            let entries = try good.entries()
            try expect(entries.count == 1, "Exactly one complete handoff must be published")
            try expect(try good.read(entries[0]) == bytes, "The successful inbox retains exact plist bytes")
            try expect(entries[0].name == "source.plist", "The display filename is preserved")
            try expect(!fm.fileExists(atPath: later.directory.path), "No later inbox is created after success")
            if name != "linked-first" {
                try expect(try Data(contentsOf: bad.directory) == sentinel, "Fallback must not overwrite a damaged path")
            } else {
                try expect(try fm.destinationOfSymbolicLink(atPath: bad.directory.path) == good.directory.path,
                           "Fallback must not replace the rejected link")
            }
        case "first-healthy":
            try publishShareFixture(bytes, name: "source.plist", inboxes: [good, bad, later])
            let entries = try good.entries()
            try expect(entries.count == 1 && (try good.read(entries[0])) == bytes, "A healthy first inbox still works")
            try expect(!fm.fileExists(atPath: later.directory.path), "Do not duplicate a completed publication")
        case "all-bad":
            var expected: NSError?
            do { _ = try bad.enqueue(bytes, name: "source.plist") } catch { expected = error as NSError }
            do {
                try publishShareFixture(bytes, name: "source.plist", inboxes: [bad, bad2])
                throw Failure(message: "All failed inboxes must report an error")
            } catch let error as Failure { throw error }
            catch {
                let actual = error as NSError
                try expect(actual.domain == expected?.domain && actual.code == expected?.code,
                           "Preserve the first concrete publication error")
            }
            try expect(try Data(contentsOf: bad.directory) == sentinel, "Keep failed publication paths intact")
        case "invalid":
            do {
                try publishShareFixture(Data("not a plist".utf8), name: "source.plist", inboxes: [good, later])
                throw Failure(message: "Invalid data must not be published")
            } catch let error as Failure { throw error }
            catch { try expect(error is SharedPlistError, "Report invalid document contents") }
            try expect(!fm.fileExists(atPath: good.directory.path) && !fm.fileExists(atPath: later.directory.path),
                       "Invalid data must not create queue directories")
        case "empty":
            do {
                try publishShareFixture(bytes, name: "source.plist", inboxes: [])
                throw Failure(message: "Missing signed inboxes must fail")
            } catch let error as Failure { throw error }
            catch let error as SharedPlistError {
                try expect(error.key == "Sign GestaltX and its share extension with the same App Group, then try again.",
                           "Keep the missing-App-Group diagnosis")
            }
        case "cancelled":
            let task = Task { @MainActor in
                try publishShareFixture(bytes, name: "source.plist", inboxes: [good, later])
            }
            task.cancel()
            do { try await task.value; throw Failure(message: "Cancelled shares must not publish") }
            catch is CancellationError { }
            try expect(!fm.fileExists(atPath: good.directory.path), "Cancellation leaves no durable handoff")
        default: throw Failure(message: "Unknown case \(name)")
        }
        print("PASS \(name)")
    }

    @MainActor static func main() async {
        let names = CommandLine.arguments.dropFirst().isEmpty
            ? ["bad-first", "two-bad", "linked-first", "first-healthy", "all-bad", "invalid", "empty", "cancelled"]
            : Array(CommandLine.arguments.dropFirst())
        do { for name in names { try await run(name) } }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
