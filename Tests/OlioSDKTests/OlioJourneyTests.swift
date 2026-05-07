import XCTest
@testable import OlioSDK

final class OlioJourneyTests: XCTestCase {

    // MARK: - Empty journey

    func testEmptyJourneyReturnsNilForAnyNextScreen() {
        let journey = OlioJourney.empty
        XCTAssertNil(journey.nextScreen(after: nil))
        XCTAssertNil(journey.nextScreen(after: "welcome"))
        XCTAssertNil(journey.nextScreen(after: "anything"))
    }

    func testEmptyJourneyShouldShowFalse() {
        let journey = OlioJourney.empty
        XCTAssertFalse(journey.shouldShow("welcome"))
        XCTAssertFalse(journey.shouldShow("paywall"))
    }

    // MARK: - nextScreen

    func testNextScreenAfterNilReturnsFirstNonSkipped() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: []
        )
        XCTAssertEqual(journey.nextScreen(after: nil), "welcome")
    }

    func testNextScreenAfterNilSkipsLeadingSkippedScreens() {
        // If the first screen is flagged skip, we should land on the first
        // non-skipped one.
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: ["welcome"]
        )
        XCTAssertEqual(journey.nextScreen(after: nil), "goal")
    }

    func testNextScreenSkipsMiddleSkippedScreen() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "social_proof", "goal", "paywall"],
            skip: ["social_proof"]
        )
        XCTAssertEqual(journey.nextScreen(after: "welcome"), "goal")
    }

    func testNextScreenAfterMidScreenReturnsNextInOrder() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: []
        )
        XCTAssertEqual(journey.nextScreen(after: "welcome"), "goal")
        XCTAssertEqual(journey.nextScreen(after: "goal"), "paywall")
    }

    func testNextScreenAfterLastScreenReturnsNil() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: []
        )
        XCTAssertNil(journey.nextScreen(after: "paywall"))
    }

    func testNextScreenAfterUnknownScreenReturnsNil() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: []
        )
        XCTAssertNil(journey.nextScreen(after: "not_in_journey"))
    }

    func testNextScreenAfterAllRemainingSkippedReturnsNil() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: ["goal", "paywall"]
        )
        XCTAssertNil(journey.nextScreen(after: "welcome"))
    }

    // MARK: - shouldShow

    func testShouldShowTrueWhenInOrderAndNotSkipped() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: []
        )
        XCTAssertTrue(journey.shouldShow("welcome"))
        XCTAssertTrue(journey.shouldShow("goal"))
        XCTAssertTrue(journey.shouldShow("paywall"))
    }

    func testShouldShowFalseWhenSkipped() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "social_proof", "goal", "paywall"],
            skip: ["social_proof"]
        )
        XCTAssertFalse(journey.shouldShow("social_proof"))
        XCTAssertTrue(journey.shouldShow("welcome"))
    }

    func testShouldShowFalseWhenNotInOrder() {
        let journey = OlioJourney(
            campaignId: "c_abc",
            order: ["welcome", "goal", "paywall"],
            skip: []
        )
        XCTAssertFalse(journey.shouldShow("not_in_journey"))
    }

    // MARK: - Equatable / sentinel

    func testEmptySentinelEqualsConstructedEmpty() {
        XCTAssertEqual(
            OlioJourney.empty,
            OlioJourney(campaignId: nil, order: [], skip: [])
        )
    }

    // MARK: - Network resolver round-trip

    func testNetworkResolverDecodesJourneyResponse() async {
        let json = #"""
        {
          "campaignId": "c_abc",
          "order": ["welcome", "goal", "paywall"],
          "skip": ["social_proof"]
        }
        """#

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com/demo")!),
            fetch: { request in
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://variants.example.com/demo/__journey/resolve"
                )
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (json.data(using: .utf8)!, response)
            }
        )

        let journey = await resolver.resolveJourney(context: nil)
        XCTAssertEqual(journey.campaignId, "c_abc")
        XCTAssertEqual(journey.order, ["welcome", "goal", "paywall"])
        XCTAssertEqual(journey.skip, ["social_proof"])
    }

    func testNetworkResolverForwardsUserIDAndAttributesOnJourney() async {
        // Same context-forwarding contract as variant resolution — verifies
        // the helpers are shared, not duplicated with a divergent shape.
        let json = #"""
        { "campaignId": null, "order": [], "skip": [] }
        """#
        let observed = JourneyObservedURLs()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com/demo")!),
            fetch: { request in
                await observed.append(request.url?.absoluteString)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (json.data(using: .utf8)!, response)
            }
        )

        _ = await resolver.resolveJourney(
            context: UserContext(
                userId: "user-abc",
                attributes: ["country": "US", "media_source": "facebook"]
            )
        )

        let urls = await observed.values
        XCTAssertEqual(urls.count, 1)
        let url = urls[0]
        XCTAssertTrue(url.hasPrefix("https://variants.example.com/demo/__journey/resolve"))
        XCTAssertTrue(url.contains("id=user-abc"))
        XCTAssertTrue(url.contains("ctx_country=US"))
        XCTAssertTrue(url.contains("ctx_media_source=facebook"))
        // Alphabetical ordering — country before media_source.
        let countryIdx = url.range(of: "ctx_country=")!.lowerBound
        let mediaIdx = url.range(of: "ctx_media_source=")!.lowerBound
        XCTAssertLessThan(countryIdx, mediaIdx)
    }

    func testNetworkResolverReturnsEmptyOn404() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com/demo")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )

        let journey = await resolver.resolveJourney(context: nil)
        XCTAssertEqual(journey, .empty)
    }

    func testNetworkResolverReturnsEmptyOnNetworkError() async {
        struct MockNetworkError: Error {}
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com/demo")!),
            fetch: { _ in throw MockNetworkError() }
        )

        let journey = await resolver.resolveJourney(context: nil)
        XCTAssertEqual(journey, .empty)
    }

    func testNetworkResolverReturnsEmptyOnMalformedJSON() async {
        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com/demo")!),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return ("{ not json".data(using: .utf8)!, response)
            }
        )

        let journey = await resolver.resolveJourney(context: nil)
        XCTAssertEqual(journey, .empty)
    }

    func testBundledResolverReturnsEmptyJourney() async {
        let resolver = BundledVariantResolver()
        let journey = await resolver.resolveJourney(context: UserContext(userId: "user-abc"))
        XCTAssertEqual(journey, .empty)
    }

    // MARK: - Olio actor wiring

    func testOlioJourneyCachesResult() async {
        let json = #"""
        {
          "campaignId": "c_abc",
          "order": ["welcome", "goal"],
          "skip": []
        }
        """#
        let counter = JourneyFetchCounter()

        let resolver = NetworkVariantResolver(
            configuration: .init(baseURL: URL(string: "https://variants.example.com/demo")!),
            fetch: { request in
                await counter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (json.data(using: .utf8)!, response)
            }
        )

        // Use a fresh Olio actor instead of `.shared` so this test doesn't
        // collide with state from other tests.
        let olio = Olio.shared
        await olio.invalidateJourney()
        await olio.configure(resolver: resolver, autoDetectMMP: false, autoCollectDeviceContext: false)

        _ = await olio.journey()
        _ = await olio.journey()
        _ = await olio.journey()

        let count = await counter.value
        XCTAssertEqual(count, 1, "Subsequent journey() calls should hit the in-memory cache")

        await olio.invalidateJourney()
        _ = await olio.journey()

        let countAfterInvalidate = await counter.value
        XCTAssertEqual(countAfterInvalidate, 2, "invalidateJourney() must force a re-fetch")
    }

    func testOlioJourneyReturnsEmptyWhenNoResolverConfigured() async {
        // Olio.shared is a singleton — we can't reset its resolver without
        // racing other tests. Instead verify .empty is returned via a
        // BundledVariantResolver whose default resolveJourney returns empty.
        let olio = Olio.shared
        await olio.invalidateJourney()
        await olio.configure(resolver: BundledVariantResolver(), autoDetectMMP: false, autoCollectDeviceContext: false)

        let journey = await olio.journey()
        XCTAssertEqual(journey, .empty)
    }
}

// MARK: - Test helpers

private actor JourneyObservedURLs {
    private(set) var values: [String] = []
    func append(_ url: String?) {
        if let url = url { values.append(url) }
    }
}

private actor JourneyFetchCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
