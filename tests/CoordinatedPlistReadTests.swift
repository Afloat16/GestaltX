import Foundation
import Darwin

private final class RedirectingCoordinator: NSFileCoordinator {
    let readableURL: URL
    private(set) var requestedURL: URL?

    init(readableURL: URL) {
        self.readableURL = readableURL
        super.init(filePresenter: nil)
    }

    override func coordinate(readingItemAt url: URL, options: NSFileCoordinator.ReadingOptions,
                             error outError: NSErrorPointer, byAccessor reader: (URL) -> Void) {
        requestedURL = url
        reader(readableURL)
    }
}

private final class FailingCoordinator: NSFileCoordinator {
    let failure = NSError(domain: "CoordinatedPlistReadTests", code: 42)

    override func coordinate(readingItemAt url: URL, options: NSFileCoordinator.ReadingOptions,
                             error outError: NSErrorPointer, byAccessor reader: (URL) -> Void) {
        outError?.pointee = failure
    }
}

@main struct CoordinatedPlistReadTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-coordinated-read-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let placeholder = root.appendingPathComponent("not-downloaded.plist")
        let readable = root.appendingPathComponent("materialized.plist")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["field": "value"]],
                                                        format: .binary, options: 0)
        try bytes.write(to: readable)
        let redirect = RedirectingCoordinator(readableURL: readable)
        let imported = try SharedPlistInbox.readDocument(at: placeholder, coordinator: redirect)
        precondition(redirect.requestedURL == placeholder)
        precondition(imported == bytes, "Read the URL supplied by the coordinator, not the placeholder")
        let local = try SharedPlistInbox.readDocument(at: readable)
        precondition(local == bytes)

        let fifo = root.appendingPathComponent("pipe.plist")
        let madeFIFO = fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
        precondition(madeFIFO == 0)
        let link = root.appendingPathComponent("link.plist")
        try fm.createSymbolicLink(at: link, withDestinationURL: readable)
        for special in [fifo, root, link] {
            let coordinator = RedirectingCoordinator(readableURL: readable)
            do {
                _ = try SharedPlistInbox.readDocument(at: special, coordinator: coordinator)
                preconditionFailure("Reject known nonregular files before invoking a coordinator")
            } catch let error as SharedPlistError {
                precondition(error.key == "The shared plist could not be read. Share it again.")
            }
            precondition(coordinator.requestedURL == nil, "A special file must not reach coordination")
        }
        // Exercise the default coordinator as well: it must never wait for a
        // writer on this real named pipe. The test runner bounds each process.
        do {
            _ = try SharedPlistInbox.readDocument(at: fifo)
            preconditionFailure("Reject a FIFO without blocking in NSFileCoordinator")
        } catch is SharedPlistError {}

        let failing = FailingCoordinator(filePresenter: nil)
        do {
            _ = try SharedPlistInbox.readDocument(at: readable, coordinator: failing)
            preconditionFailure("A coordination failure must not fall back to an uncoordinated read")
        } catch {
            precondition((error as NSError) == failing.failure)
        }
        try Data("invalid".utf8).write(to: readable)
        do {
            _ = try SharedPlistInbox.readDocument(at: placeholder, coordinator: redirect)
            preconditionFailure("Validate the coordinated bytes before accepting an import")
        } catch let error as SharedPlistError {
            precondition(error.key == "Choose a MobileGestalt plist with a CacheExtra dictionary.")
        }
        try Data(repeating: 0, count: SharedPlistInbox.maximumByteCount + 1).write(to: readable)
        do {
            _ = try SharedPlistInbox.readDocument(at: placeholder, coordinator: redirect)
            preconditionFailure("Coordinated reads must retain the byte limit")
        } catch let error as SharedPlistError {
            precondition(error.key == "Choose a plist smaller than 16 MB.")
        }
        print("PASS: coordinated URL reads, missing placeholders, nonregular-file preflight, coordination errors and bounded reads.")
    }
}
