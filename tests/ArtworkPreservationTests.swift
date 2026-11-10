import Foundation

struct ArtworkTestFailure: Error { let message: String }

func expectArtwork(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ArtworkTestFailure(message: message) }
}

@main struct ArtworkPreservationTests {
    static func document(artwork: Any?, format: PropertyListSerialization.PropertyListFormat) throws -> GestaltDocument {
        var extra: [String: Any] = [
            "Unrelated": ["bytes": Data([3, 1, 4]), "enabled": true],
            "Z/dqyWS6OZTRy10UcmUAhw": "Original model",
            "bbtR9jQx50Fv5Af/affNtA": "Original model",
            "YlEtTtHlNesRBMal1CqRaA": false,
        ]
        if let artwork { extra[GestaltKeys.artwork] = artwork }
        let root: [String: Any] = ["CacheExtra": extra, "CacheData": Data([9, 8, 7]), "OtherRootKey": "preserved"]
        return try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0))
    }

    static func main() throws {
        let malformed: [(String, Any)] = [
            ("string", "legacy artwork"),
            ("data", Data([0, 255, 17])),
            ("array", ["legacy", ["nested": true]] as [Any]),
            ("integer", NSNumber(value: 42)),
            ("real", NSNumber(value: 1.5)),
            ("boolean", NSNumber(value: true)),
            ("date", Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let edits: [(String, Any)] = [
            ("ArtworkDeviceProductDescription", "Edited model"),
            ("ArtworkDeviceSubType", NSNumber(value: 2556)),
        ]
        let formats: [PropertyListSerialization.PropertyListFormat] = [.xml, .binary]
        var rejectedEdits = 0
        for format in formats {
            // Both an absent value and an existing empty dictionary remain editable.
            let emptyArtwork: [Any?] = [nil, [String: Any]()]
            for initial in emptyArtwork {
                var edited = try document(artwork: initial, format: format)
                for (key, value) in edits { _ = edited.setArtwork(value, for: key) }
                let expected = try document(artwork: Dictionary(uniqueKeysWithValues: edits), format: format)
                try expectArtwork(edited.matches(expected), "Create missing artwork fields without changing other values")
                try expectArtwork(try GestaltDocument(data: edited.encoded()).matches(expected), "New artwork survives serialization")
            }

            let originalArtwork: [String: Any] = [
                "ArtworkDeviceProductDescription": "Original model",
                "VendorBytes": Data([0, 1, 255]),
                "VendorValues": ["enabled": true, "count": NSNumber(value: 7), "scale": NSNumber(value: 0.5)],
            ]
            var edited = try document(artwork: originalArtwork, format: format)
            for (key, value) in edits { _ = edited.setArtwork(value, for: key) }
            var expectedArtwork = originalArtwork
            expectedArtwork["ArtworkDeviceProductDescription"] = "Edited model"
            expectedArtwork["ArtworkDeviceSubType"] = NSNumber(value: 2556)
            let expected = try document(artwork: expectedArtwork, format: format)
            try expectArtwork(edited.matches(expected), "Retain unknown artwork keys and their exact types")
            try expectArtwork(try GestaltDocument(data: edited.encoded()).matches(expected), "Existing artwork survives serialization")

            for (kind, value) in malformed {
                let original = try document(artwork: value, format: format)
                for (key, replacement) in edits {
                    var unchanged = original
                    // Ignore the return value so this regression also runs against
                    // the original void-returning setter and fails on data loss.
                    _ = unchanged.setArtwork(replacement, for: key)
                    try expectArtwork(unchanged.matches(original), "Preserve malformed \(kind) artwork when editing \(key)")
                    try expectArtwork(try GestaltDocument(data: unchanged.encoded()).matches(original), "Preserve malformed \(kind) artwork through serialization")
                    rejectedEdits += 1
                }
            }
        }
        print("PASS: \(rejectedEdits) malformed artwork edits preserve the complete document; XML/binary missing, empty and unknown-key dictionary controls pass.")
    }
}
