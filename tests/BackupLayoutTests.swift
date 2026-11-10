import Foundation

@main struct BackupLayoutTests {
    struct Failure: Error { let message: String }
    final class Trace: @unchecked Sendable { var writes = 0 }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        let root: [String: Any] = [
            "CacheExtra": ["VasUgeSzVyHdB27g2XpN0g": "same-device", "setting": "original"],
            "CacheUUID": "current-layout", "CacheVersion": "current-version", "CacheData": Data([0, 1, 2])
        ]
        func bytes(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        let original = try bytes(root)
        try original.write(to: device)
        let trace = Trace()
        let store = GestaltFileStore(deviceURL: device, backupDirectory: directory.appendingPathComponent("backups"), deviceID: "layout-fixture", acquire: { 1 }, release: { _ in }, writeData: { data, url in
            trace.writes += 1
            try data.write(to: url)
        })
        let initial = try await store.loadDevice()
        let record = try await store.backups().first!
        var variants: [[String: Any]] = []
        var changed = root; changed["CacheUUID"] = "previous-layout"; variants.append(changed)
        changed = root; changed["CacheVersion"] = "previous-version"; variants.append(changed)
        changed = root; changed["CacheData"] = Data([0, 1]); variants.append(changed)
        changed = root; changed.removeValue(forKey: "CacheUUID"); variants.append(changed)
        changed = root; changed.removeValue(forKey: "CacheVersion"); variants.append(changed)
        changed = root; changed["CacheData"] = "invalid"; variants.append(changed)
        for variant in variants {
            let restored = try GestaltDocument(data: bytes(variant))
            do {
                _ = try await store.commit(restored, expected: initial, restoring: record)
                throw Failure(message: "Incompatible same-device backup reached the writer")
            } catch is GestaltFailure {}
            try expect(trace.writes == 0 && (try Data(contentsOf: device)) == original, "Layout rejection leaves the device untouched")
            try expect(try await store.backups().count == 1, "Layout rejection precedes backup and journal side effects")
        }
        var matching = initial.document
        matching.set("restored", for: "setting")
        let restored = try await store.commit(matching, expected: initial, restoring: record)
        try expect(trace.writes == 1 && restored.document.matches(matching), "Matching cache layouts can be restored")
        let local = try await store.loadLocal(data: original, name: "old-local.plist")
        let oldLayout = try GestaltDocument(data: bytes(variants[0]))
        let opened = try await store.commit(oldLayout, expected: local, restoring: record)
        try expect(opened.source == .local && opened.document.matches(oldLayout), "Old backups can still be opened as local documents")
        try expect(trace.writes == 1, "Opening an incompatible backup locally never writes the device")
        print("PASS: UUID, version, data-length and missing-metadata restore rejection; compatible restore and local access.")
    }
}
