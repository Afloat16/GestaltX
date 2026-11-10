import Foundation
import Darwin

struct InboxTestFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw InboxTestFailure(message: message) }
}
func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is InboxTestFailure { throw InboxTestFailure(message: message) } catch { return }
    throw InboxTestFailure(message: message)
}

@main struct SharedPlistInboxTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-share-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let group = root.appendingPathComponent("resigned-group")
        let inbox = try SharedPlistInbox(container: group, namespace: "com.example.resigned")
        let other = try SharedPlistInbox(container: group, namespace: "com.example.other")
        let document: [String: Any] = ["CacheExtra": ["string": "hello", "boolean": true, "integer": 1], "CacheData": Data([1, 2, 3])]
        let binary = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        let xml = try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
        let source = root.appendingPathComponent("original.plist")
        try binary.write(to: source)
        let read = try SharedPlistInbox.readDocument(at: source)
        let first = try inbox.enqueue(read, name: "../../original\n.plist")
        try check(first.name == "original.plist", "Filenames are display metadata and cannot escape the inbox")
        try check(try inbox.read(first) == binary, "Publish and read exact binary plist bytes")
        try check(try Data(contentsOf: source) == binary, "Sharing never changes the user's original file")
        try check(try other.entries().isEmpty, "Different app instances do not consume each other's files")
        // Simulate a cold start after the extension process has already exited.
        let restarted = try SharedPlistInbox(container: group, namespace: "com.example.resigned")
        try check(try restarted.entries().map(\.id) == [first.id], "Completed handoff survives process restart")
        let second = try restarted.enqueue(xml, name: "same-name.plist")
        let third = try restarted.enqueue(binary, name: "same-name.plist")
        try check(second.id != third.id && (try restarted.entries().count) == 3, "Duplicate filenames never overwrite queued files")
        try check(try restarted.read(second) == xml, "XML plist is accepted without converting its values")
        try restarted.acknowledge(first)
        try check(try restarted.entries().map(\.id) == [second.id, third.id], "Acknowledge removes only the imported entry")
        let staged = restarted.directory.appendingPathComponent(".interrupted.pending")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try binary.write(to: staged.appendingPathComponent("document.plist"))
        try check(try restarted.entries().count == 2, "Partial publications are never imported")
        try rejects("Reject a path-traversal namespace") { _ = try SharedPlistInbox(container: group, namespace: "../escape") }
        try rejects("Reject a non-file URL") { _ = try SharedPlistInbox.readDocument(at: URL(string: "https://example.com/test.plist")!) }
        try rejects("Reject a non-plist") { _ = try inbox.enqueue(Data("hello".utf8), name: "wrong.plist") }
        let invalid = try PropertyListSerialization.data(fromPropertyList: ["NotMobileGestalt": true], format: .binary, options: 0)
        try rejects("Reject plist without CacheExtra") { _ = try inbox.enqueue(invalid, name: "wrong.plist") }
        let oversized = root.appendingPathComponent("oversized.plist")
        try Data(repeating: 0, count: SharedPlistInbox.maximumByteCount + 1).write(to: oversized)
        try rejects("Bound the file read before parsing") { _ = try SharedPlistInbox.readDocument(at: oversized) }
        // A damaged published file is rejected, retained, and removed from the
        // automatic queue so it cannot repeatedly replace a current document.
        let secondPayload = restarted.directory.appendingPathComponent(second.id.uuidString).appendingPathComponent("document.plist")
        try Data("corrupt".utf8).write(to: secondPayload)
        try rejects("Revalidate a modified queue payload") { _ = try restarted.read(second) }
        restarted.reject(second)
        try check(try restarted.entries().map(\.id) == [third.id], "Quarantine a broken entry without blocking the queue")
        let thirdPayload = restarted.directory.appendingPathComponent(third.id.uuidString).appendingPathComponent("document.plist")
        try fm.removeItem(at: thirdPayload)
        try fm.createSymbolicLink(at: thirdPayload, withDestinationURL: source)
        try rejects("Reject symlinked queue documents") { _ = try restarted.read(third) }
        try check(try Data(contentsOf: source) == binary, "Rejected queue links cannot change the source")
        let special = try SharedPlistInbox(container: group, namespace: "special-files")
        let metadataEntry = try special.enqueue(binary, name: "metadata.plist")
        let metadata = special.directory.appendingPathComponent(metadataEntry.id.uuidString).appendingPathComponent("entry.json")
        let savedMetadata = root.appendingPathComponent("saved-entry.json")
        try fm.moveItem(at: metadata, to: savedMetadata)
        try fm.createSymbolicLink(at: metadata, withDestinationURL: savedMetadata)
        try check(try special.entries().isEmpty, "Ignore symlinked metadata instead of following it")
        try fm.removeItem(at: metadata)
        let madeFIFO = metadata.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
        try check(madeFIFO == 0, "Create a named-pipe metadata fixture")
        try check(try special.entries().isEmpty, "A metadata FIFO with no writer must not block the inbox scan")
        try rejects("Reject a document FIFO without waiting for a writer") { _ = try SharedPlistInbox.readDocument(at: metadata) }
        try rejects("Reject directories as documents") { _ = try SharedPlistInbox.readDocument(at: root) }
        try fm.removeItem(at: metadata)
        try fm.moveItem(at: savedMetadata, to: metadata)
        try check(try special.read(metadataEntry) == binary, "Normal documents remain readable after malformed queue entries")
        print("PASS: share-inbox binary/XML validation, bounded reads, atomic handoff, cold-start recovery, re-signed namespaces, duplicate names, isolated acknowledgement and corrupt-file quarantine.")
    }
}
