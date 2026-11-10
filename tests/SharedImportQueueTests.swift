import Foundation

@main struct SharedImportQueueTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["fixture": true]], format: .binary, options: 0)
        func inbox(_ name: String) throws -> SharedPlistInbox {
            try SharedPlistInbox(container: root, namespace: name)
        }
        func corrupt(_ entry: SharedPlistEntry, in inbox: SharedPlistInbox) throws {
            try Data("broken".utf8).write(to: inbox.directory.appendingPathComponent(entry.id.uuidString).appendingPathComponent("document.plist"))
        }
        func validate(_ inbox: SharedPlistInbox, _ entry: SharedPlistEntry) -> SharedImportPreparation<SharedPlistEntry> {
            do { _ = try inbox.read(entry); return .ready(entry) }
            catch { inbox.reject(entry); return .rejected(error.localizedDescription) }
        }

        let mixed = try inbox("mixed")
        let invalid = try mixed.enqueue(bytes, name: "invalid.plist")
        let first = try mixed.enqueue(bytes, name: "first-valid.plist")
        let second = try mixed.enqueue(bytes, name: "second-valid.plist")
        let third = try mixed.enqueue(bytes, name: "third-valid.plist")
        try corrupt(invalid, in: mixed)
        var attempted: [UUID] = []
        let selected = await SharedImportQueue.next(in: try SharedImportQueue.snapshot(in: [mixed])) { inbox, entry in
            attempted.append(entry.id)
            return validate(inbox, entry)
        }
        guard case .ready(let offer) = selected else { throw Failure(message: "A rejected first entry must not hide the following valid entry") }
        try expect(offer.id == first.id && attempted == [invalid.id, first.id], "One check skips rejection and stops at the first confirmation")
        try expect(selected.blocksAutomaticRead, "A pending confirmation defers automatic device reading")
        try expect(try mixed.entries().map(\.id) == [first.id, second.id, third.id], "Only the rejected file is quarantined before confirmation")

        // Both confirmation actions acknowledge only the displayed entry. A new
        // snapshot then offers the next item, without another foreground event.
        try mixed.acknowledge(offer) // Cancel the first offer.
        let afterCancel = await SharedImportQueue.next(in: try SharedImportQueue.snapshot(in: [mixed]), prepare: validate)
        guard case .ready(let next) = afterCancel else { throw Failure(message: "Cancel must allow the next confirmation") }
        try expect(next.id == second.id, "Cancellation advances in queue order")
        try mixed.acknowledge(next) // Accept the second offer.
        let afterAccept = await SharedImportQueue.next(in: try SharedImportQueue.snapshot(in: [mixed]), prepare: validate)
        guard case .ready(let last) = afterAccept else { throw Failure(message: "Acceptance must allow the next confirmation") }
        try expect(last.id == third.id, "Acceptance advances in queue order")
        try mixed.acknowledge(last)
        let drained = await SharedImportQueue.next(in: try SharedImportQueue.snapshot(in: [mixed]), prepare: validate)
        try expect(!drained.blocksAutomaticRead, "A drained queue permits initial automatic reading to resume")

        let rejected = try inbox("rejected")
        for name in ["one", "two", "three"] {
            let entry = try rejected.enqueue(bytes, name: name)
            try corrupt(entry, in: rejected)
        }
        let allInvalid = await SharedImportQueue.next(in: try SharedImportQueue.snapshot(in: [rejected]), prepare: validate)
        guard case .empty(let message) = allInvalid else { throw Failure(message: "An all-invalid queue must finish in this check") }
        try expect(message != nil && !allInvalid.blocksAutomaticRead, "An all-invalid queue reports rejection without suppressing automatic reading")
        try expect(try rejected.entries().isEmpty, "All rejected entries leave the visible inbox")

        let deferred = try inbox("deferred")
        let waiting = try deferred.enqueue(bytes, name: "needs-device-access")
        _ = try deferred.enqueue(bytes, name: "later")
        var deferredAttempts = 0
        let paused: SharedImportQueue.Selection<SharedPlistEntry> = await SharedImportQueue.next(in: try SharedImportQueue.snapshot(in: [deferred])) { _, _ in
            deferredAttempts += 1
            return .deferred("Device access is temporarily unavailable")
        }
        guard case .deferred = paused else { throw Failure(message: "Temporary verification failure must defer the queue") }
        try expect(deferredAttempts == 1 && paused.blocksAutomaticRead, "A deferred item is visited once and stops this pass")
        let waitingEntries = try deferred.entries()
        try expect(waitingEntries.first?.id == waiting.id && waitingEntries.count == 2, "Deferred files remain queued for a later explicit retry")

        let growing = try inbox("growing")
        _ = try growing.enqueue(bytes, name: "captured")
        let snapshot = try SharedImportQueue.snapshot(in: [growing])
        var boundedAttempts = 0
        let bounded: SharedImportQueue.Selection<SharedPlistEntry> = await SharedImportQueue.next(in: snapshot) { inbox, _ in
            boundedAttempts += 1
            do { _ = try inbox.enqueue(bytes, name: "arrived-during-verification") }
            catch { return .deferred(error.localizedDescription) }
            // Deliberately leave the first entry visible to simulate a failed
            // quarantine operation. The captured snapshot is still finite.
            return .rejected("Could not quarantine")
        }
        try expect(boundedAttempts == 1 && !bounded.blocksAutomaticRead, "New arrivals and failed quarantine cannot create a retry loop")
        try expect(try growing.entries().count == 2, "New arrivals are retained for the next snapshot")
        print("PASS: invalid-to-valid draining, sequential cancellation/acceptance, all-invalid fallback, deferred retention and bounded snapshots.")
    }
}
