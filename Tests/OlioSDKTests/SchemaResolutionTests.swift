import XCTest
import SwiftUI
@testable import OlioSDK

final class SchemaResolutionTests: XCTestCase {

    // MARK: - URL construction

    func testDefaultSchemaURLBuilder() {
        let base = URL(string: "https://variants.tryolio.app/acme")!
        let url = NetworkVariantResolver.defaultSchemaURLBuilder(base, "welcome")
        XCTAssertEqual(url.absoluteString, "https://variants.tryolio.app/acme/__schema/welcome")
    }

    func testDefaultSchemaURLBuilderWithRootBase() {
        let base = URL(string: "https://variants.example.com")!
        let url = NetworkVariantResolver.defaultSchemaURLBuilder(base, "paywall")
        XCTAssertEqual(url.absoluteString, "https://variants.example.com/__schema/paywall")
    }

    // MARK: - Successful fetch

    func testResolveSchemaSucceedsAndDecodes() async {
        let schemaJSON = #"""
        {
          "elements": [
            { "type": "static",  "label": "Welcome" },
            { "type": "dynamic", "slot":  "heading" },
            { "type": "dynamic", "slot":  "primary_cta" }
          ]
        }
        """#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com/acme")!),
            fetch: { request in
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://variants.example.com/acme/__schema/welcome"
                )
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                XCTAssertNil(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Schema endpoint is read-public — must not send Authorization"
                )
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (schemaJSON.data(using: .utf8)!, response)
            }
        )

        let schema = await resolver.resolveSchema(screen: "welcome")
        XCTAssertNotNil(schema)
        XCTAssertEqual(schema?.elements.count, 3)
        XCTAssertEqual(schema?.dynamicSlotKeys, ["heading", "primary_cta"])
    }

    func testResolveSchemaDoesNotForwardAuthorizationHeader() async {
        // Variant fetches send Bearer tokens; schema fetches must NOT.
        let schemaJSON = #"{ "elements": [] }"#

        let resolver = NetworkVariantResolver(
            configuration: .init(
                baseURL: URL(string: "https://variants.example.com")!,
                authorizationHeader: "Bearer secret_token"
            ),
            fetch: { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (schemaJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolveSchema(screen: "welcome")
    }

    // MARK: - Failure modes

    func testResolveSchemaReturns404AsNil() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        let schema = await resolver.resolveSchema(screen: "no_schema_here")
        XCTAssertNil(schema)
    }

    func testResolveSchemaReturnsNilOn500() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        let schema = await resolver.resolveSchema(screen: "welcome")
        XCTAssertNil(schema)
    }

    func testResolveSchemaReturnsNilOnNetworkError() async {
        struct MockNetworkError: Error {}
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { _ in throw MockNetworkError() }
        )
        let schema = await resolver.resolveSchema(screen: "welcome")
        XCTAssertNil(schema)
    }

    func testResolveSchemaReturnsNilOnMalformedJSON() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (#"{ "elements": [ { "type": "alien" } ] }"#.data(using: .utf8)!, response)
            }
        )
        let schema = await resolver.resolveSchema(screen: "welcome")
        XCTAssertNil(schema, "Unknown element type should degrade to nil, not throw")
    }

    // MARK: - Caching

    func testResolveSchemaCachesSuccessfulResponses() async {
        let counter = SchemaFetchCounter()
        let schemaJSON = #"{ "elements": [ { "type": "dynamic", "slot": "heading" } ] }"#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (schemaJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolveSchema(screen: "welcome")
        _ = await resolver.resolveSchema(screen: "welcome")
        _ = await resolver.resolveSchema(screen: "welcome")

        let count = await counter.value
        XCTAssertEqual(count, 1, "Schema should be cached after first successful fetch")
    }

    func testResolveSchemaCacheKeyDistinguishesByScreen() async {
        let counter = SchemaFetchCounter()
        let schemaJSON = #"{ "elements": [] }"#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (schemaJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolveSchema(screen: "welcome")
        _ = await resolver.resolveSchema(screen: "paywall")
        _ = await resolver.resolveSchema(screen: "welcome") // hit cache

        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    // MARK: - Cache isolation between variant + schema

    func testVariantAndSchemaCacheAreIndependent() async {
        let counter = SchemaFetchCounter()
        let variantJSON = #"{ "screenId": "welcome", "variantId": "v1", "slots": {} }"#
        let schemaJSON = #"{ "elements": [] }"#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.url!.path.contains("__schema") {
                    return (schemaJSON.data(using: .utf8)!, response)
                } else {
                    return (variantJSON.data(using: .utf8)!, response)
                }
            }
        )

        _ = await resolver.resolve(screen: "welcome", attribution: nil)
        _ = await resolver.resolveSchema(screen: "welcome")
        _ = await resolver.resolve(screen: "welcome", attribution: nil) // variant cache hit
        _ = await resolver.resolveSchema(screen: "welcome")              // schema cache hit

        let count = await counter.value
        XCTAssertEqual(count, 2, "Variant + schema should fetch once each, then hit independent caches")
    }

    func testClearCacheClearsBothVariantAndSchema() async {
        let counter = SchemaFetchCounter()
        let variantJSON = #"{ "screenId": "welcome", "variantId": "v1", "slots": {} }"#
        let schemaJSON = #"{ "elements": [] }"#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.url!.path.contains("__schema") {
                    return (schemaJSON.data(using: .utf8)!, response)
                } else {
                    return (variantJSON.data(using: .utf8)!, response)
                }
            }
        )

        _ = await resolver.resolve(screen: "welcome", attribution: nil)
        _ = await resolver.resolveSchema(screen: "welcome")
        await resolver.clearCache()
        _ = await resolver.resolve(screen: "welcome", attribution: nil)
        _ = await resolver.resolveSchema(screen: "welcome")

        let count = await counter.value
        XCTAssertEqual(count, 4, "After clearCache, both variant and schema should refetch")
    }

    // MARK: - Custom URL builder

    func testCustomSchemaURLBuilder() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(
                baseURL: URL(string: "https://api.example.com")!,
                schemaURLBuilder: { base, screen in
                    var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    c.path = "/v1/screens/\(screen.raw)/schema"
                    return c.url!
                }
            ),
            fetch: { request in
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://api.example.com/v1/screens/welcome/schema"
                )
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (#"{ "elements": [] }"#.data(using: .utf8)!, response)
            }
        )
        _ = await resolver.resolveSchema(screen: "welcome")
    }

    // MARK: - VariantResolver protocol default

    func testBundledResolverReturnsNilSchemaByDefault() async {
        let resolver = BundledVariantResolver(directoryName: "TryolioVariants")
        // BundledVariantResolver doesn't override resolveSchema; protocol
        // default returns nil and existing call sites stay unchanged.
        let schema = await resolver.resolveSchema(screen: "welcome")
        XCTAssertNil(schema)
    }

    func testProtocolDefaultResolveSchemaReturnsNil() async {
        struct NoSchemaResolver: VariantResolver {
            func resolve(screen: ScreenID, attribution: AttributionContext?) async -> VariantPayload? { nil }
        }
        let resolver = NoSchemaResolver()
        let schema = await resolver.resolveSchema(screen: "welcome")
        XCTAssertNil(schema)
    }

    // MARK: - validateVariant

    func testValidateVariantDoesNotCrashOnMissingSchemaSlot() {
        // Schema lists [heading, subhead, primary_cta]; variant has [heading, subhead].
        // Should warn about primary_cta and never crash.
        let payload = makeVariantPayload(slots: ["heading", "subhead"])
        let schema = ScreenSchema(elements: [
            .dynamic(slot: "heading"),
            .dynamic(slot: "subhead"),
            .dynamic(slot: "primary_cta")
        ])
        PersonalizableScreen<EmptyView>.validateVariant(payload, against: schema, screenID: "welcome")
    }

    func testValidateVariantHandlesExtraVariantSlot() {
        // Variant has slots [heading, subhead, extra_thing]; schema lists [heading, subhead].
        // extra_thing is permissive.
        let payload = makeVariantPayload(slots: ["heading", "subhead", "extra_thing"])
        let schema = ScreenSchema(elements: [
            .dynamic(slot: "heading"),
            .dynamic(slot: "subhead")
        ])
        PersonalizableScreen<EmptyView>.validateVariant(payload, against: schema, screenID: "welcome")
    }

    func testValidateVariantTotalAgreement() {
        let payload = makeVariantPayload(slots: ["heading", "primary_cta"])
        let schema = ScreenSchema(elements: [
            .static(label: "Header"),
            .dynamic(slot: "heading"),
            .static(label: "Footer"),
            .dynamic(slot: "primary_cta")
        ])
        PersonalizableScreen<EmptyView>.validateVariant(payload, against: schema, screenID: "welcome")
    }

    func testValidateVariantStaticElementsAreNotValidated() {
        // Static elements must not be flagged as missing slots even if variant has nothing.
        let payload = makeVariantPayload(slots: [])
        let schema = ScreenSchema(elements: [
            .static(label: "Hello"),
            .static(label: "World")
        ])
        PersonalizableScreen<EmptyView>.validateVariant(payload, against: schema, screenID: "welcome")
    }

    // MARK: - VariantPayload.slotIDs accessor

    func testVariantPayloadSlotIDsReportsAllSlots() {
        let payload = makeVariantPayload(slots: ["heading", "primary_cta", "hero"])
        let slots = Set(payload.slotIDs.map(\.raw))
        XCTAssertEqual(slots, ["heading", "primary_cta", "hero"])
    }

    // MARK: - Helpers

    private func makeVariantPayload(slots: [String]) -> VariantPayload {
        if slots.isEmpty {
            let json = #"{ "screenId": "welcome", "variantId": "v1", "slots": {} }"#
            return try! JSONDecoder().decode(VariantPayload.self, from: json.data(using: .utf8)!)
        }
        let slotsJSON = slots
            .map { "\"\($0)\": { \"type\": \"HeadingContent\", \"headline\": \"\($0)\" }" }
            .joined(separator: ",\n      ")

        let json = """
        {
          "screenId": "welcome",
          "variantId": "v1",
          "slots": {
            \(slotsJSON)
          }
        }
        """
        return try! JSONDecoder().decode(VariantPayload.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - Test fixtures

private actor SchemaFetchCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
