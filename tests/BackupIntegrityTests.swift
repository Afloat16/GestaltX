import Foundation

@main struct BackupIntegrityTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func expectRejected(_ store: GestaltFileStore, record: BackupRecord) async throws {
        do {
            _ = try await store.backupData(record)
            throw Failure(message: "Corrupt backup passed integrity checks")
        } catch is GestaltFailure {}
    }

    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        let backups = directory.appendingPathComponent("backups")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["setting": "alpha"]], format: .binary, options: 0)
        try bytes.write(to: device)
        let store = GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: "integrity-fixture", acquire: { 1 }, release: { _ in })
        _ = try await store.loadDevice()
        let record = try await store.backups().first!
        try expect(try await store.backupData(record) == bytes, "Unchanged backup passes verification")
        let backupURL = backups.appendingPathComponent(record.filename)
        var altered = try GestaltDocument(data: bytes)
        altered.set("omega", for: "setting")
        let replacement = try altered.encoded()
        try expect(replacement.count == record.byteCount, "Fixture replacement is a different valid plist of identical size")
        try replacement.write(to: backupURL)
        try await expectRejected(store, record: record)
        try Data(bytes.dropLast()).write(to: backupURL)
        try await expectRejected(store, record: record)
        try bytes.write(to: backupURL)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: backups.appendingPathComponent(record.id.uuidString + ".json"))) as! [String: Any]
        try expect((metadata["sha256"] as? String)?.count == 64, "New backup metadata persists a SHA-256 digest")

        // Decode the actual old schema, rather than relying only on the new
        // initializer's default argument, to verify backward compatibility.
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        legacyJSON.removeValue(forKey: "sha256")
        let legacy = try JSONDecoder().decode(BackupRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        try expect(try await store.backupData(legacy) == bytes, "Legacy backups of the recorded length remain readable")
        try Data(bytes.dropLast()).write(to: backupURL)
        try await expectRejected(store, record: legacy)
        try bytes.write(to: backupURL)
        var wrongDigestJSON = metadata
        wrongDigestJSON["sha256"] = String(repeating: "0", count: 64)
        let wrongDigest = try JSONDecoder().decode(BackupRecord.self, from: JSONSerialization.data(withJSONObject: wrongDigestJSON))
        try await expectRejected(store, record: wrongDigest)
        try expect(try Data(contentsOf: device) == bytes, "Rejected backup reads never modify the device")
        print("PASS: persisted checksums, same-size corruption, truncation, legacy metadata and unchanged device bytes.")
    }
}
