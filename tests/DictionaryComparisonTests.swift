// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct DictionaryComparisonTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func document(_ values: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> GestaltDocument {
        try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: ["CacheExtra": values], format: format, options: 0))
    }
    static func correctness() throws {
        let values: [String: Any] = [
            "nested": ["array": [NSNumber(value: UInt64(42)), Data([0, 255]), "text"] as [Any],
                       "boolean": NSNumber(value: true), "date": Date(timeIntervalSince1970: 100)],
            "integer": NSNumber(value: 1), "real": NSNumber(value: 1.0), "empty": [String: Any]()
        ]
        let original = try document(values)
        let reversed = Dictionary(uniqueKeysWithValues: values.reversed())
        try expect(original.matches(try document(reversed, format: .xml)), "Insertion order and plist encoding do not change equality")
        var different = values
        different["replacement"] = different.removeValue(forKey: "integer")
        try expect(!original.matches(try document(different)), "Equal-size dictionaries with different keys must differ")
        different = values; different["extra"] = "new"
        try expect(!original.matches(try document(different)), "Additional keys must differ")
        different = values; different.removeValue(forKey: "empty")
        try expect(!original.matches(try document(different)), "Missing empty dictionaries must differ")
        different = values; different["integer"] = NSNumber(value: true)
        try expect(!original.matches(try document(different)), "Boolean and integer values retain distinct plist types")
        different = values; different["real"] = NSNumber(value: 2.0)
        try expect(!original.matches(try document(different)), "Changed scalar values must differ")
        different = values; different["nested"] = ["different": "keys", "boolean": true, "date": Date(timeIntervalSince1970: 100)]
        try expect(!original.matches(try document(different)), "Nested key mismatches must differ")
        try expect(try document([:]).matches(document([:])), "Empty dictionaries compare equal")
        print("PASS dictionary comparison correctness: 8 cases")
    }

    @inline(never) static func matches(_ left: GestaltDocument, _ right: GestaltDocument) -> Bool {
        left.matches(right)
    }
    static func benchmark(_ kind: String) throws {
        var values: [String: Any] = [:]
        if kind == "wide" {
            for index in 0..<30000 { values["key-\(index)"] = NSNumber(value: index) }
        } else {
            for group in 0..<400 {
                var nested: [String: Any] = [:]
                for index in 0..<60 { nested["field-\(index)"] = NSNumber(value: group * 60 + index) }
                values["group-\(group)"] = nested
            }
        }
        let left = try document(values)
        let right = try document(values)
        for _ in 0..<2 { try expect(matches(left, right), "Benchmark documents must match") }
        let repetitions = 12
        var samples: [Double] = []
        var matched = 0
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<repetitions { if matches(left, right) { matched += 1 } }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        try expect(matched == 5 * repetitions, "Every measured comparison must complete")
        let result: [String: Any] = ["case": kind, "samples_seconds": samples,
                                   "comparisons_per_sample": repetitions, "matched": matched]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
    static func main() throws {
        let selected = CommandLine.arguments.dropFirst().first ?? "correctness"
        if selected == "correctness" { try correctness() }
        else if selected == "wide" || selected == "nested" { try benchmark(selected) }
        else { throw Failure(message: "Unknown case: " + selected) }
    }
}
