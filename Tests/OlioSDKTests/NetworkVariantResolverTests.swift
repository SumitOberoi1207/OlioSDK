import XCTest
@testable import OlioSDK

final class NetworkVariantResolverTests: XCTestCase {

    // MARK: - URL construction

    func testDefaultURLBuilderWithoutVariantKey() {
        let base = URL(string: "https://variants.example.com")!
        let url = NetworkVariantResolver.defaultURLBuilder(base, "welcome", nil)
        XCTAssertEqual(url.absoluteString, "https://variants.example.com/welcome.json")
    }

    func testDefaultURLBuilderWithVariantKey() {
        let base = URL(string: "https://variants.example.com")!
        let url = NetworkVariantResolver.defaultURLBuilder(base, "welcome", "fb_stress")
        XCTAssertEqual(url.absoluteString, "https://variants.example.com/welcome.fb_stress.json")
    }

    func testDefaultURLBuilderWithSubpathBase() {
        let base = URL(string: "https://cdn.example.com/tryolio/v1")!
        let url = NetworkVariantResolver.defaultURLBuilder(base, "paywall", "fb_sleep")
        XCTAssertEqual(url.absoluteString, "https://cdn.example.com/tryolio/v1/paywall.fb_sleep.json")
    }

    // MARK: - Successful fetch

    func testResolveSucceedsAndDecodes() async throws {
        let payloadJSON = #"""
        {
          "screenId": "welcome",
          "variantId": "fb_stress_v1",
          "slots": {
            "heading": {
              "type": "HeadingContent",
              "headline": "Breathe through anything"
            }
          }
        }
        """#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://variants.example.com/welcome.fb_stress.json")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (payloadJSON.data(using: .utf8)!, response)
            }
        )

        let attribution = AttributionContext(mediaSource: "facebook_ads", campaign: "stress_relief_q2")
        let payload = await resolver.resolve(screen: "welcome", attribution: attribution)

        XCTAssertEqual(payload?.screenId, "welcome")
        XCTAssertEqual(payload?.variantId, "fb_stress_v1")
        let heading: HeadingContent? = payload?.content(for: "heading")
        XCTAssertEqual(heading?.headline, "Breathe through anything")
    }

    // MARK: - Failure modes (fail-open)

    func testResolveReturnsNilOn404() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        let payload = await resolver.resolve(screen: "missing", attribution: nil)
        XCTAssertNil(payload)
    }

    func testResolveReturnsNilOn500() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        let payload = await resolver.resolve(screen: "welcome", attribution: nil)
        XCTAssertNil(payload)
    }

    func testResolveReturnsNilOnNetworkError() async {
        struct MockNetworkError: Error {}
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { _ in throw MockNetworkError() }
        )
        let payload = await resolver.resolve(screen: "welcome", attribution: nil)
        XCTAssertNil(payload)
    }

    func testResolveReturnsNilOnMalformedJSON() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return ("{ this is not json".data(using: .utf8)!, response)
            }
        )
        let payload = await resolver.resolve(screen: "welcome", attribution: nil)
        XCTAssertNil(payload)
    }

    // MARK: - Caching

    func testResolveCachesSuccessfulResponses() async {
        var fetchCount = 0
        let payloadJSON = #"""
        { "screenId": "welcome", "variantId": "v1", "slots": {} }
        """#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                fetchCount += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (payloadJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(screen: "welcome", attribution: nil)
        _ = await resolver.resolve(screen: "welcome", attribution: nil)
        _ = await resolver.resolve(screen: "welcome", attribution: nil)

        XCTAssertEqual(fetchCount, 1, "Subsequent resolves should hit the in-memory cache")
    }

    func testCacheKeyDistinguishesByVariantKey() async {
        var fetchCount = 0
        let payloadJSON = #"""
        { "screenId": "welcome", "variantId": "v1", "slots": {} }
        """#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                fetchCount += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (payloadJSON.data(using: .utf8)!, response)
            }
        )

        let stress = AttributionContext(mediaSource: "facebook_ads", campaign: "stress_relief_q2")
        let sleep = AttributionContext(mediaSource: "facebook_ads", campaign: "sleep_better_q2")

        _ = await resolver.resolve(screen: "welcome", attribution: stress)
        _ = await resolver.resolve(screen: "welcome", attribution: sleep)
        _ = await resolver.resolve(screen: "welcome", attribution: stress) // should hit cache

        XCTAssertEqual(fetchCount, 2, "Different variant keys should fetch separately, but repeat keys hit cache")
    }

    // MARK: - Override

    func testOverrideBypassesAttributionMapping() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://variants.example.com/welcome.qa_test.json",
                    "Override should win over attribution-derived variant key"
                )
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )

        await resolver.setActiveVariantOverride("qa_test")
        let attribution = AttributionContext(mediaSource: "facebook_ads", campaign: "stress_relief_q2")
        _ = await resolver.resolve(screen: "welcome", attribution: attribution)
    }

    // MARK: - Custom configuration

    func testCustomURLBuilderUsed() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(
                baseURL: URL(string: "https://api.example.com")!,
                urlBuilder: { base, screen, variant in
                    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    components.path = "/v1/screens/\(screen.raw)"
                    if let variant = variant {
                        components.queryItems = [URLQueryItem(name: "variant", value: variant)]
                    }
                    return components.url!
                }
            ),
            fetch: { request in
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://api.example.com/v1/screens/welcome?variant=fb_stress"
                )
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return ("{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }".data(using: .utf8)!, response)
            }
        )

        let attribution = AttributionContext(mediaSource: "facebook_ads", campaign: "stress_relief_q2")
        _ = await resolver.resolve(screen: "welcome", attribution: attribution)
    }

    func testAuthorizationHeaderForwarded() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(
                baseURL: URL(string: "https://variants.example.com")!,
                authorizationHeader: "Bearer test_token_123"
            ),
            fetch: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test_token_123")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return ("{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }".data(using: .utf8)!, response)
            }
        )
        _ = await resolver.resolve(screen: "welcome", attribution: nil)
    }

    // MARK: - Server-side targeting (UserContext)

    func testUserContextAppendsIDQueryOnDefaultRequest() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(userId: "user-abc")
        )

        let urls = await observed.values
        XCTAssertEqual(urls, ["https://variants.example.com/welcome.json?id=user-abc"])
    }

    func testNoUserContextOmitsIDQuery() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(screen: "welcome", attribution: nil, context: nil)
        _ = await resolver.resolve(screen: "paywall", attribution: nil, context: UserContext(userId: nil))

        let urls = await observed.values
        XCTAssertEqual(urls, [
            "https://variants.example.com/welcome.json",
            "https://variants.example.com/paywall.json"
        ])
        XCTAssertFalse(urls.contains { $0.contains("?id=") }, "URLs must not include ?id= when userId is absent")
    }

    func testExplicitVariantKeyBypassesTargeting() async {
        // Even with a userContext, an attribution-derived variant key takes
        // the deterministic path and must not append `?id=`.
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        let attribution = AttributionContext(mediaSource: "facebook_ads", campaign: "stress_relief_q2")
        _ = await resolver.resolve(
            screen: "welcome",
            attribution: attribution,
            context: UserContext(userId: "user-abc")
        )

        let urls = await observed.values
        XCTAssertEqual(urls, ["https://variants.example.com/welcome.fb_stress.json"])
    }

    func testCacheIsolatesAcrossUserIDs() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let counter = FetchCounter()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(screen: "welcome", attribution: nil, context: UserContext(userId: "user-A"))
        _ = await resolver.resolve(screen: "welcome", attribution: nil, context: UserContext(userId: "user-B"))
        // Repeat user-A: should hit cache.
        _ = await resolver.resolve(screen: "welcome", attribution: nil, context: UserContext(userId: "user-A"))

        let count = await counter.value
        XCTAssertEqual(count, 2, "Different userIds must fetch independently; repeats hit cache")
    }

    func testBackwardCompatibleResolveStillWorks() async {
        // Existing call sites (no `context:` argument) must keep working
        // unchanged via the protocol's two-arg overload on the actor.
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://variants.example.com/welcome.json")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        let payload = await resolver.resolve(screen: "welcome", attribution: nil)
        XCTAssertEqual(payload?.screenId, "welcome")
    }

    func testCustomURLBuilderQueryItemsPreservedWithIDAppended() async {
        // A custom urlBuilder may already attach query items; appending `?id`
        // must not clobber them.
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(
                baseURL: URL(string: "https://api.example.com")!,
                urlBuilder: { base, screen, _ in
                    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    components.path = "/v1/screens/\(screen.raw)"
                    components.queryItems = [URLQueryItem(name: "tenant", value: "demo")]
                    return components.url!
                }
            ),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(userId: "user-abc")
        )

        let urls = await observed.values
        XCTAssertEqual(urls.count, 1)
        let url = urls[0]
        XCTAssertTrue(url.contains("tenant=demo"), "Existing query items must be preserved, got: \(url)")
        XCTAssertTrue(url.contains("id=user-abc"), "id query param must be appended, got: \(url)")
    }

    func testUserIDIsURLEncodedInQuery() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(userId: "user with spaces&plus+signs")
        )

        let urls = await observed.values
        XCTAssertEqual(urls.count, 1)
        // URLQueryItem encodes spaces and `&` and `+`. Exact encoding may vary
        // by platform — assert key invariants rather than a literal string.
        let url = urls[0]
        XCTAssertTrue(url.hasPrefix("https://variants.example.com/welcome.json?id="))
        XCTAssertFalse(url.contains(" "), "Raw spaces should be percent-encoded, got: \(url)")
        // Decoded round-trip should match the original userId.
        let parsed = URLComponents(string: url)!
        let idItem = parsed.queryItems?.first { $0.name == "id" }
        XCTAssertEqual(idItem?.value, "user with spaces&plus+signs")
    }

    // MARK: - UserContext.attributes -> ?ctx_* query params

    func testUserContextAttributesAppendCtxQueryItemsInAlphabeticalOrder() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(
                userId: nil,
                attributes: ["media_source": "facebook", "campaign": "stress_q4"]
            )
        )

        let urls = await observed.values
        XCTAssertEqual(urls.count, 1)
        let url = urls[0]

        // Both ctx params present
        XCTAssertTrue(url.contains("ctx_campaign=stress_q4"), "expected ctx_campaign=stress_q4 in: \(url)")
        XCTAssertTrue(url.contains("ctx_media_source=facebook"), "expected ctx_media_source=facebook in: \(url)")

        // Alphabetical: campaign appears before media_source.
        let campaignIdx = url.range(of: "ctx_campaign=")!.lowerBound
        let mediaIdx = url.range(of: "ctx_media_source=")!.lowerBound
        XCTAssertLessThan(campaignIdx, mediaIdx, "ctx_* params must be in sorted key order")

        // Round-trip via URLComponents to verify encoding is well-formed.
        let parsed = URLComponents(string: url)!
        let items = parsed.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "ctx_campaign" }?.value, "stress_q4")
        XCTAssertEqual(items.first { $0.name == "ctx_media_source" }?.value, "facebook")
    }

    func testUserContextEmptyAttributeValuesAreStripped() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(
                userId: nil,
                attributes: ["media_source": "facebook", "campaign": ""]
            )
        )

        let urls = await observed.values
        XCTAssertEqual(urls.count, 1)
        let url = urls[0]
        XCTAssertTrue(url.contains("ctx_media_source=facebook"))
        XCTAssertFalse(url.contains("ctx_campaign"), "empty-string attribute values must be stripped, got: \(url)")
    }

    func testCacheIsolatesAcrossAttributeValues() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let counter = FetchCounter()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(userId: nil, attributes: ["campaign": "stress_q4"])
        )
        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(userId: nil, attributes: ["campaign": "sleep_q4"])
        )

        let count = await counter.value
        XCTAssertEqual(count, 2, "Different attribute values must fetch independently")
    }

    func testCacheDeduplicatesIdenticalAttributes() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let counter = FetchCounter()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        let attrs = ["media_source": "facebook", "campaign": "stress_q4"]
        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(userId: nil, attributes: attrs)
        )
        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(userId: nil, attributes: attrs)
        )
        // Same attributes in different insertion order — should still cache-hit
        // because we sort by key before building the signature.
        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(
                userId: nil,
                attributes: ["campaign": "stress_q4", "media_source": "facebook"]
            )
        )

        let count = await counter.value
        XCTAssertEqual(count, 1, "Identical (and order-insensitive) attribute sets must hit cache")
    }

    func testExplicitVariantKeyDoesNotIncludeCtxParams() async {
        // Even with attributes set, an attribution-derived variant key takes
        // the deterministic path and must not append `ctx_*` (matching the
        // existing `?id=` behavior).
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        let attribution = AttributionContext(mediaSource: "facebook_ads", campaign: "stress_relief_q2")
        _ = await resolver.resolve(
            screen: "welcome",
            attribution: attribution,
            context: UserContext(
                userId: "user-abc",
                attributes: ["media_source": "facebook", "campaign": "stress_q4"]
            )
        )

        let urls = await observed.values
        XCTAssertEqual(urls, ["https://variants.example.com/welcome.fb_stress.json"])
        XCTAssertFalse(urls[0].contains("ctx_"), "Explicit variant requests must not include ctx_* params")
    }

    func testCtxAttributeSpecialCharactersAreURLEncoded() async {
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(
                userId: nil,
                attributes: ["raw_value": "a&b=c d"]
            )
        )

        let urls = await observed.values
        XCTAssertEqual(urls.count, 1)
        let url = urls[0]
        // No raw spaces should leak into the URL.
        XCTAssertFalse(url.contains(" "), "Raw spaces should be percent-encoded, got: \(url)")
        // Decoded round-trip should preserve the original value (so &/=/space
        // aren't being treated as additional separators).
        let parsed = URLComponents(string: url)!
        let item = parsed.queryItems?.first { $0.name == "ctx_raw_value" }
        XCTAssertEqual(item?.value, "a&b=c d")
    }

    func testCtxAttributesPreserveExistingQueryItemsFromCustomBuilder() async {
        // A custom urlBuilder may already attach query items; appending ctx_*
        // params (alongside `?id`) must preserve them.
        let okJSON = "{ \"screenId\": \"welcome\", \"variantId\": \"v1\", \"slots\": {} }"
        let observed = ObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(
                baseURL: URL(string: "https://api.example.com")!,
                urlBuilder: { base, screen, _ in
                    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    components.path = "/v1/screens/\(screen.raw)"
                    components.queryItems = [URLQueryItem(name: "tenant", value: "demo")]
                    return components.url!
                }
            ),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (okJSON.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolve(
            screen: "welcome",
            attribution: nil,
            context: UserContext(
                userId: "user-abc",
                attributes: ["campaign": "stress_q4"]
            )
        )

        let urls = await observed.values
        XCTAssertEqual(urls.count, 1)
        let url = urls[0]
        XCTAssertTrue(url.contains("tenant=demo"), "Existing query items must be preserved, got: \(url)")
        XCTAssertTrue(url.contains("id=user-abc"), "id query param must be appended, got: \(url)")
        XCTAssertTrue(url.contains("ctx_campaign=stress_q4"), "ctx_* must be appended, got: \(url)")
    }
}

// MARK: - Test helpers (Sendable-safe collectors for closure capture)

private actor ObservedURLs {
    private(set) var values: [String] = []
    func append(_ url: String?) {
        if let url = url { values.append(url) }
    }
}

private actor FetchCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
