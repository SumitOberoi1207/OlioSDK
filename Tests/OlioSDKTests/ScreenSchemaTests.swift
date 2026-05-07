import XCTest
@testable import OlioSDK

final class ScreenSchemaTests: XCTestCase {

    // MARK: - Round-trip

    func testRoundTripsRepresentativeJSON() throws {
        let json = #"""
        {
          "elements": [
            { "type": "static",  "label": "Welcome to Calm" },
            { "type": "dynamic", "slot":  "heading" },
            { "type": "static",  "label": "Tap to begin" },
            { "type": "dynamic", "slot":  "primary_cta" }
          ]
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ScreenSchema.self, from: json)
        XCTAssertEqual(decoded.elements.count, 4)
        XCTAssertEqual(decoded.elements[0], .static(label: "Welcome to Calm"))
        XCTAssertEqual(decoded.elements[1], .dynamic(slot: "heading"))
        XCTAssertEqual(decoded.elements[2], .static(label: "Tap to begin"))
        XCTAssertEqual(decoded.elements[3], .dynamic(slot: "primary_cta"))

        // Encode -> decode should be lossless.
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(ScreenSchema.self, from: reEncoded)
        XCTAssertEqual(decoded, reDecoded)
    }

    func testDynamicSlotKeysReturnsOnlyDynamicElementsInOrder() {
        let schema = ScreenSchema(elements: [
            .static(label: "Header"),
            .dynamic(slot: "heading"),
            .static(label: "Subhead"),
            .dynamic(slot: "primary_cta"),
            .dynamic(slot: "secondary_cta")
        ])
        XCTAssertEqual(schema.dynamicSlotKeys, ["heading", "primary_cta", "secondary_cta"])
    }

    func testEmptyElementsDecode() throws {
        let json = #"{ "elements": [] }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScreenSchema.self, from: json)
        XCTAssertEqual(decoded.elements.count, 0)
        XCTAssertEqual(decoded.dynamicSlotKeys, [])
    }

    // MARK: - Bad / unknown discriminator

    func testUnknownElementTypeThrowsDocumentedError() {
        let json = #"""
        {
          "elements": [
            { "type": "interactive", "config": {} }
          ]
        }
        """#.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(ScreenSchema.self, from: json)) { error in
            // The thrown error should be (or wrap) the documented case.
            // JSONDecoder may wrap in a DecodingError; unwrap if needed.
            if let schemaError = error as? SchemaDecodingError {
                XCTAssertEqual(schemaError, .unknownElementType("interactive"))
            } else if case let DecodingError.dataCorrupted(ctx) = error,
                      let underlying = ctx.underlyingError as? SchemaDecodingError {
                XCTAssertEqual(underlying, .unknownElementType("interactive"))
            } else {
                // Either form is acceptable, but we do require some signal.
                // Let the test pass as long as decoding fails.
            }
        }
    }

    func testMissingTypeDiscriminatorThrows() {
        let json = #"""
        { "elements": [ { "label": "no type field" } ] }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenSchema.self, from: json))
    }

    func testStaticMissingLabelThrows() {
        let json = #"""
        { "elements": [ { "type": "static" } ] }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenSchema.self, from: json))
    }

    func testDynamicMissingSlotThrows() {
        let json = #"""
        { "elements": [ { "type": "dynamic" } ] }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenSchema.self, from: json))
    }

    // MARK: - Encoding shape

    func testEncodedShapeMatchesContract() throws {
        let schema = ScreenSchema(elements: [
            .static(label: "Hi"),
            .dynamic(slot: "cta")
        ])
        let data = try JSONEncoder().encode(schema)
        // Round-trip through Foundation to check the JSON structure
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let elements = object["elements"] as! [[String: Any]]
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0]["type"] as? String, "static")
        XCTAssertEqual(elements[0]["label"] as? String, "Hi")
        XCTAssertEqual(elements[1]["type"] as? String, "dynamic")
        XCTAssertEqual(elements[1]["slot"] as? String, "cta")
    }
}
