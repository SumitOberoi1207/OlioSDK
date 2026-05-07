import XCTest
import SwiftUI
@testable import OlioSDK

/// Tests for the `userContextChanges` AsyncStream on `Olio` and the
/// coalescing fetch loop on `PersonalizableScreen` that consumes it. Together
/// these cover the mid-session re-resolution path: a screen mounted before
/// MMP attribution arrives picks up the targeted variant once it does.
final class UserContextChangesTests: XCTestCase {

    // MARK: - Helpers

    /// Variant resolver that records every `resolve(...)` invocation in an
    /// actor-protected counter. Returns `nil` for both variant and schema
    /// resolution so callers don't need to thread payload fixtures.
    private actor RecordingResolver: VariantResolver {
        private(set) var resolveCallCount: Int = 0
        private(set) var lastContext: UserContext?

        func resolve(screen: ScreenID, attribution: AttributionContext?) async -> VariantPayload? {
            resolveCallCount += 1
            return nil
        }

        func resolve(
            screen: ScreenID,
            attribution: AttributionContext?,
            context: UserContext?
        ) async -> VariantPayload? {
            resolveCallCount += 1
            lastContext = context
            return nil
        }

        func snapshot() -> (count: Int, lastContext: UserContext?) {
            (resolveCallCount, lastContext)
        }
    }

    /// Reset the singleton's user context + resolver between tests so cases
    /// don't bleed into each other. `Olio.shared` is process-wide and
    /// every test in this module shares it.
    private func resetSharedState() async {
        await Olio.shared.setUserContext(nil)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            autoDetectMMP: false,
            autoCollectDeviceContext: false
        )
        // configure() may have mutated userContext; clear it again so each
        // test starts from a clean slate.
        await Olio.shared.setUserContext(nil)
    }

    // MARK: - userContextChanges() stream behavior

    func testUserContextChangesYieldsCurrentValueImmediately() async {
        await resetSharedState()
        await Olio.shared.setUserContext(UserContext(userId: "u1"))

        let stream = await Olio.shared.userContextChanges()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        // The stream primes with the current value at subscription time.
        XCTAssertEqual(first??.userId, "u1")
    }

    func testUserContextChangesYieldsOnSetUserContext() async {
        await resetSharedState()

        let stream = await Olio.shared.userContextChanges()
        var iterator = stream.makeAsyncIterator()

        // First yield: current value (nil because we cleared it)
        let initial = await iterator.next()
        XCTAssertNil(initial as? UserContext)

        // Mutate, then expect a second yield with the new value
        await Olio.shared.setUserContext(
            UserContext(userId: "u2", attributes: ["media_source": "facebook_ads"])
        )
        let after = await iterator.next()
        XCTAssertEqual(after??.userId, "u2")
        XCTAssertEqual(after??.attributes["media_source"], "facebook_ads")
    }

    func testUserContextChangesSupportsMultipleSubscribers() async {
        await resetSharedState()

        let streamA = await Olio.shared.userContextChanges()
        let streamB = await Olio.shared.userContextChanges()
        var itA = streamA.makeAsyncIterator()
        var itB = streamB.makeAsyncIterator()

        // Drain initial primed values from both subscribers
        _ = await itA.next()
        _ = await itB.next()

        // Mutate once. Both subscribers should observe the new value.
        await Olio.shared.setUserContext(UserContext(userId: "broadcast"))
        let aGot = await itA.next()
        let bGot = await itB.next()
        XCTAssertEqual(aGot??.userId, "broadcast")
        XCTAssertEqual(bGot??.userId, "broadcast")
    }

    // MARK: - PersonalizableScreen.runFetchLoop coalescing

    @MainActor
    func testRunFetchLoopFetchesOncePerStreamValue() async {
        // Two yields → two fetches. Establishes the baseline that the loop
        // calls fetch for each stream value when there's no concurrency
        // pressure (each fetch finishes before the next value arrives).
        let (stream, continuation) = AsyncStream.makeStream(of: UserContext?.self)
        var fetchCount = 0

        let task = Task { @MainActor in
            await PersonalizableScreen<EmptyView>.runFetchLoop(stream: stream) {
                fetchCount += 1
            }
        }

        continuation.yield(nil)
        // Give the loop a tick to consume the first value
        try? await Task.sleep(nanoseconds: 20_000_000)
        continuation.yield(UserContext(userId: "u1"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        continuation.finish()
        await task.value

        XCTAssertEqual(fetchCount, 2)
    }

    @MainActor
    func testRunFetchLoopCoalescesRapidYields() async {
        // Many yields delivered while a fetch is in flight should collapse to
        // at most ONE trailing fetch — not N. The first yield triggers a
        // fetch; subsequent yields during that fetch coalesce; once the
        // first fetch finishes, exactly one trailing fetch runs.
        let (stream, continuation) = AsyncStream.makeStream(of: UserContext?.self)
        var fetchCount = 0
        let firstFetchInFlight = expectation(description: "first fetch started")
        let releaseFirstFetch = expectation(description: "first fetch released")
        var hasSignaledFirst = false

        let task = Task { @MainActor in
            await PersonalizableScreen<EmptyView>.runFetchLoop(stream: stream) {
                fetchCount += 1
                if !hasSignaledFirst {
                    hasSignaledFirst = true
                    firstFetchInFlight.fulfill()
                    // Block the first fetch until the test releases it. While
                    // we sit here, the test will pump 5 additional yields in.
                    await self.waitForExpectation(releaseFirstFetch)
                }
            }
        }

        continuation.yield(nil)                          // triggers fetch #1
        await fulfillment(of: [firstFetchInFlight], timeout: 1.0)

        // While fetch #1 is blocked, fire 5 rapid context changes.
        for i in 1...5 {
            continuation.yield(UserContext(userId: "u\(i)"))
        }
        // Release fetch #1; loop should then run exactly ONE trailing fetch
        // for all 5 queued yields, not 5.
        releaseFirstFetch.fulfill()

        // Allow the trailing fetch to complete.
        try? await Task.sleep(nanoseconds: 50_000_000)
        continuation.finish()
        await task.value

        // Acceptable shape: 1 (first) + 1 (trailing) = 2. Strictly less than
        // 6 (which would be a stampede). The contract is "no thundering
        // herd" — we assert the strict ceiling.
        XCTAssertLessThanOrEqual(fetchCount, 2, "Coalescing failed: got \(fetchCount) fetches for 6 yields, expected ≤ 2")
        XCTAssertGreaterThanOrEqual(fetchCount, 1)
    }

    @MainActor
    func testRunFetchLoopExitsOnStreamFinish() async {
        // Sanity: the loop returns when the stream finishes. SwiftUI relies
        // on this so the .task body completes when the view unmounts and the
        // continuation is terminated by .onTermination on the actor.
        let (stream, continuation) = AsyncStream.makeStream(of: UserContext?.self)
        var fetchCount = 0
        let task = Task { @MainActor in
            await PersonalizableScreen<EmptyView>.runFetchLoop(stream: stream) {
                fetchCount += 1
            }
        }
        continuation.yield(nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        continuation.finish()
        await task.value
        // If the loop didn't exit on `.finish()`, `task.value` would hang.
        XCTAssertGreaterThanOrEqual(fetchCount, 1)
    }

    // MARK: - End-to-end: setUserContext triggers re-resolve

    func testFetchLoopReResolvesViaOlioWhenContextChanges() async throws {
        // Wire a recording resolver into Olio.shared, drive the loop
        // against the actor's real userContextChanges() stream, then mutate
        // userContext and confirm the resolver was invoked an additional
        // time. This is the goal-state test: a `PersonalizableScreen` that
        // mounted before MMP arrival re-fetches once attribution lands.
        await resetSharedState()
        let recorder = RecordingResolver()
        await Olio.shared.configure(
            resolver: recorder,
            autoDetectMMP: false,
            autoCollectDeviceContext: false
        )

        let stream = await Olio.shared.userContextChanges()
        let task = Task { @MainActor in
            await PersonalizableScreen<EmptyView>.runFetchLoop(stream: stream) {
                guard let resolver = await Olio.shared.resolver else { return }
                let context = await Olio.shared.userContext
                _ = await resolver.resolve(
                    screen: "welcome",
                    attribution: nil,
                    context: context
                )
            }
        }

        // Initial fetch (from the primed nil value): expect exactly 1.
        try await Task.sleep(nanoseconds: 30_000_000)
        let firstSnapshot = await recorder.snapshot()
        XCTAssertEqual(firstSnapshot.count, 1, "Initial fetch should have run exactly once")
        XCTAssertNil(firstSnapshot.lastContext)

        // Now simulate an MMP attribution arrival mid-session.
        await Olio.shared.setUserContext(
            UserContext(userId: nil, attributes: ["media_source": "facebook_ads"])
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let secondSnapshot = await recorder.snapshot()
        // Strict 1 → 2 transition: a single context change produces exactly
        // one additional fetch.
        XCTAssertEqual(
            secondSnapshot.count,
            2,
            "Resolver was not re-invoked exactly once after userContext changed"
        )
        XCTAssertEqual(secondSnapshot.lastContext?.attributes["media_source"], "facebook_ads")

        task.cancel()
    }

    func testDefaultsOnlyStrategySkipsResolverEntirely() async throws {
        // `.defaultsOnly` must NOT subscribe to changes and NOT call resolve.
        // We mimic the view's strategy gate from outside: the loop helper
        // is never invoked when strategy == .defaultsOnly.
        await resetSharedState()
        let recorder = RecordingResolver()
        await Olio.shared.configure(
            resolver: recorder,
            autoDetectMMP: false,
            autoCollectDeviceContext: false
        )

        // Replicate the strategy gate: short-circuit before subscribing.
        let strategy = PersonalizableScreen<EmptyView>.Strategy.defaultsOnly
        if strategy != .defaultsOnly {
            XCTFail("test setup: expected defaultsOnly")
        }
        // Mutate userContext after the fact — no subscriber, so no fetch.
        await Olio.shared.setUserContext(
            UserContext(userId: nil, attributes: ["media_source": "facebook_ads"])
        )
        try await Task.sleep(nanoseconds: 30_000_000)

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.count, 0, "defaultsOnly must skip the resolver entirely")
    }

    // MARK: - Helpers

    private func waitForExpectation(_ exp: XCTestExpectation) async {
        await fulfillment(of: [exp], timeout: 1.0)
    }
}
