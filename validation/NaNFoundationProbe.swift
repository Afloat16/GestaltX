import Foundation

@main struct NaNFoundationProbe {
    static func main() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CacheExtra</key><dict>
        <key>measurement</key><real>nan</real>
        <key>nested</key><array><dict><key>value</key><real>nan</real></dict></array>
        </dict></dict></plist>
        """.utf8)
        let document = try GestaltDocument(data: xml)
        guard let number = document.extra["measurement"] as? NSNumber, number.doubleValue.isNaN else {
            fatalError("Foundation did not accept the XML NaN fixture")
        }
        let binary = try document.encoded()
        let reopened = try GestaltDocument(data: binary)
        guard (reopened.extra["measurement"] as? NSNumber)?.doubleValue.isNaN == true else {
            fatalError("Foundation did not preserve NaN in a binary plist")
        }
        print("FOUNDATION: XML and binary plists both preserve NaN")
        print("DOCUMENT_SELF_MATCH: \(document.matches(document))")
        print("BINARY_ROUNDTRIP_MATCH: \(document.matches(reopened))")
        let key = Data(repeating: 19, count: 32)
        let sealed = try DeviceBoundPlist.seal(binary, key: key)
        do {
            _ = try DeviceBoundPlist.verify(sealed, key: key)
            print("OWN_PROOF_VERIFY: success")
        } catch {
            print("OWN_PROOF_VERIFY: rejected: \(error.localizedDescription)")
        }
        guard !document.matches(document), !document.matches(reopened) else {
            fatalError("The current document implementation no longer reproduces the comparison bug")
        }
        print("REPRODUCED: valid property-list NaN makes unmodified documents compare unequal")
    }
}
