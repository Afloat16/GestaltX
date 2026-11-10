import Foundation

@main struct IntegerValueTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() async throws {
        let values: [NSNumber] = [
            NSNumber(value: Int64.min), NSNumber(value: Int64(-1)),
            NSNumber(value: Int64(0)), NSNumber(value: Int64.max),
            NSNumber(value: UInt64(Int64.max) + 1), NSNumber(value: UInt64.max)
        ]
        for number in values {
            let text = PlistValueKind.integer.text(for: number)
            let parsed = try PlistValueKind.integer.parse(text)
            try expect(GestaltDocument.valuesEqual(number, parsed), "Integer text preserves every 64-bit boundary: " + text)
            let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["identifier": number]], format: .binary, options: 0)
            let document = try GestaltDocument(data: bytes)
            try expect(GestaltDocument.valuesEqual(number, document.extra["identifier"]!), "Binary plist roundtrip preserves " + text)
        }
        for invalid in ["18446744073709551616", "-9223372036854775809", "1.5", "NaN"] {
            do {
                _ = try PlistValueKind.integer.parse(invalid)
                throw Failure(message: "Out-of-range or noninteger value was accepted: " + invalid)
            } catch is GestaltFailure {}
        }
        let unsigned = NSNumber(value: UInt64.max), signed = NSNumber(value: Int64(-1))
        try expect(!GestaltDocument.valuesEqual(unsigned, signed), "Unsigned maximum must not alias signed -1")
        try expect(!GestaltDocument.valuesEqual([unsigned], [signed]), "Array comparison preserves signedness at the boundary")
        try expect(!GestaltDocument.valuesEqual(["id": unsigned], ["id": signed]), "Dictionary comparison preserves signedness at the boundary")
        try expect(GestaltDocument.valuesEqual(NSNumber(value: UInt64(42)), NSNumber(value: Int64(42))), "Equal positive signed and unsigned integers compare equally")
        try expect(!GestaltDocument.valuesEqual(NSNumber(value: true), NSNumber(value: 1)), "Boolean and integer remain distinct")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["identifier": NSNumber(value: 0)]], format: .binary, options: 0)
        try original.write(to: device)
        let store = GestaltFileStore(deviceURL: device, backupDirectory: directory.appendingPathComponent("backups"), deviceID: "integer-fixture", acquire: { 1 }, release: { _ in }, writeData: { data, url in
            var corrupted = try GestaltDocument(data: data)
            corrupted.set(NSNumber(value: Int64(-1)), for: "identifier")
            try corrupted.encoded().write(to: url)
        })
        let initial = try await store.loadDevice()
        var edited = initial.document
        edited.set(unsigned, for: "identifier")
        do {
            _ = try await store.commit(edited, expected: initial)
            throw Failure(message: "Readback must reject replacement of UInt64.max with -1")
        } catch is GestaltFailure {}
        try expect(try Data(contentsOf: device) == original, "Mismatched integer readback restores the previous file")
        print("PASS: full 64-bit integer parsing, exact comparisons, binary roundtrips and readback rollback.")
    }
}
