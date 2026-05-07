import SwiftUI

/// A SwiftUI container that fetches the variant payload for a screen and publishes
/// it to descendant slots via the SwiftUI environment.
///
/// Drop this around any view that contains slots:
///
///     struct WelcomeScreen: View {
///         var body: some View {
///             PersonalizableScreen(id: "welcome") {
///                 VStack {
///                     HeadingSlot(id: "heading") { Text("Default") }
///                     CTASlot(id: "primary_cta") { Button("Continue") {} }
///                 }
///             }
///         }
///     }
///
/// One container per screen does one variant resolution; all slots inside read
/// their content from the resolved payload. Failure modes (network down, no
/// variant matched, malformed payload) all degrade to slot defaults — the
/// container never crashes the host app.
public struct PersonalizableScreen<Content: View>: View {
    let screenID: ScreenID
    let strategy: Strategy
    @ViewBuilder let content: () -> Content

    @State private var payload: VariantPayload?

    public enum Strategy: Sendable {
        /// Show defaults immediately; swap to variant content when payload arrives.
        case immediate
        /// Don't fetch — slots use defaults. Useful for previews and tests.
        case defaultsOnly
    }

    public init(
        id: ScreenID,
        strategy: Strategy = .immediate,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.screenID = id
        self.strategy = strategy
        self.content = content
    }

    public var body: some View {
        content()
            .environment(\.variantPayload, payload)
            .task(id: screenID) {
                await runFetchLoop()
            }
    }

    /// Drive the initial fetch and then keep listening for `userContext`
    /// changes (host `setUserContext`, MMP attribution merge, default
    /// collection) and re-resolving on each change.
    ///
    /// Lifecycle: SwiftUI's `.task(id:)` cancels this whenever `screenID`
    /// changes or the view disappears. The cancellation propagates into the
    /// child tasks inside `runFetchLoop(stream:fetch:)`, which exit cleanly.
    /// The stream's `.onTermination` hook on the Olio actor unregisters
    /// our continuation when the cancellation drains the AsyncStream.
    ///
    /// Debounce: see the static `runFetchLoop(stream:fetch:)` for details.
    /// Short version: we never run two `fetchPayload()` calls concurrently;
    /// rapid context changes during a fetch coalesce into a single trailing
    /// fetch.
    @MainActor
    private func runFetchLoop() async {
        // .defaultsOnly skips the initial fetch and the subscription: no
        // network is ever issued in this mode, so re-resolving on context
        // change would be wasted work.
        guard strategy != .defaultsOnly else { return }

        // Subscribe BEFORE the initial fetch so we can't lose a context change
        // delivered between the initial fetch's `Olio.shared.userContext`
        // read and the moment we'd otherwise start iterating. The actor
        // primes the stream with the current value, so the first `for await`
        // yields immediately and triggers the initial fetch — we don't need a
        // separate "first fetch" call.
        let stream = await Olio.shared.userContextChanges()
        await PersonalizableScreen.runFetchLoop(stream: stream) {
            await fetchPayload()
        }
    }

    /// Coalescing fetch loop, factored out so tests can drive it directly with
    /// a known sequence of stream events and a recording fetch closure. The
    /// view body wraps this in a `Olio.shared.userContextChanges()` stream.
    ///
    /// Coalescing rule: we never run two `fetch` calls concurrently. While a
    /// fetch is in flight, additional stream values are consumed off the
    /// stream but only bump a "dirty" counter — they don't queue up
    /// independent fetches. After the in-flight fetch finishes, if the
    /// counter advanced, exactly one trailing fetch runs to incorporate
    /// every change. Multiple rapid arrivals collapse to a single trailing
    /// fetch — so SDK-collection + MMP-arrival firing within milliseconds
    /// settles as one re-resolve, not a thundering herd.
    ///
    /// Implementation: two concurrent child tasks share a small state actor.
    /// The reader pumps the stream and bumps the dirty counter; the worker
    /// fetches whenever the counter advances past the last serviced version.
    /// Both exit cleanly when the stream finishes or the parent task is
    /// cancelled.
    @MainActor
    static func runFetchLoop<S: AsyncSequence & Sendable>(
        stream: S,
        fetch: @escaping @MainActor @Sendable () async -> Void
    ) async where S.Element == UserContext? {
        let coordinator = FetchLoopCoordinator()

        await withTaskGroup(of: Void.self) { group in
            // Reader task: pump every stream value into the coordinator, then
            // close it when the stream finishes so the worker can exit.
            group.addTask {
                do {
                    for try await _ in stream {
                        await coordinator.markDirty()
                    }
                } catch {
                    // AsyncStream<UserContext?> never throws; tolerate
                    // throwing AsyncSequences (test fixtures) by treating
                    // errors as end-of-stream.
                }
                await coordinator.close()
            }

            // Worker task: wait for dirty signals and fetch. Coalesces
            // multiple bumps that occur during a fetch into a single
            // trailing fetch.
            group.addTask { @MainActor in
                while await coordinator.waitForWork() {
                    await fetch()
                }
            }
        }
    }

    @MainActor
    private func fetchPayload() async {
        guard strategy != .defaultsOnly else { return }
        guard let resolver = await Olio.shared.resolver else { return }
        let attribution = await Olio.shared.attributionProvider?.attribution()
        let context = await Olio.shared.userContext

        // Variant + schema are independent reads; fetch in parallel so we
        // don't pay the schema round trip in series. Schema is purely for
        // dev-time validation — it never blocks rendering.
        async let resolvedVariant = resolver.resolve(
            screen: screenID,
            attribution: attribution,
            context: context
        )
        async let resolvedSchema = resolver.resolveSchema(screen: screenID)

        let (variant, schema) = await (resolvedVariant, resolvedSchema)

        if let variant, let schema {
            PersonalizableScreen.validateVariant(variant, against: schema, screenID: screenID)
        }

        // Animate dependent view updates so the variant swap feels intentional
        // rather than a jump-cut. Customers can opt out by wrapping their
        // slot bodies in `.transaction { $0.disablesAnimations = true }`.
        withAnimation(.easeInOut(duration: 0.25)) {
            payload = variant
        }
    }

    /// Compare a resolved variant payload against a screen schema and surface
    /// dev-time mismatches. Purely informational — never throws, never alters
    /// rendering. Logs are gated behind `#if DEBUG` so production builds stay
    /// silent.
    ///
    /// - Missing-on-variant: schema lists a dynamic slot the variant doesn't
    ///   define → warning. The slot will fall back to its default closure.
    /// - Extra-on-variant: variant defines a slot the schema doesn't list as
    ///   dynamic → info. Variants are permissive; this is informational only.
    /// - Static elements are not validated — they're host-side chrome.
    static func validateVariant(
        _ payload: VariantPayload,
        against schema: ScreenSchema,
        screenID: ScreenID
    ) {
        #if DEBUG
        let schemaSlots = Set(schema.dynamicSlotKeys)
        let variantSlots = Set(payload.slotIDs.map(\.raw))

        for slot in schemaSlots.subtracting(variantSlots).sorted() {
            print("[Olio] ⚠️ Variant for screen \"\(screenID)\" is missing slot \"\(slot)\" declared in schema")
        }
        for key in variantSlots.subtracting(schemaSlots).sorted() {
            print("[Olio] ℹ️ Variant for screen \"\(screenID)\" defines slot \"\(key)\" not in schema (variant is permissive)")
        }
        #endif
    }
}

extension PersonalizableScreen.Strategy: Equatable {}

/// Coalesces stream-value bumps into "do work" signals for the fetch loop.
///
/// Used internally by `PersonalizableScreen.runFetchLoop`. Two concurrent
/// callers cooperate: the reader calls `markDirty()` for each stream value
/// and `close()` when the stream finishes; the worker calls `waitForWork()`
/// in a loop and runs a fetch each time it returns `true`.
///
/// **Coalescing semantics:** while the worker is running a fetch (i.e. the
/// reader keeps calling `markDirty()` faster than the worker can drain),
/// every bump just sets `dirty = true` on the same shared flag. When the
/// worker returns to `waitForWork()` after its fetch completes, it consumes
/// the flag in one shot and runs one more fetch — regardless of how many
/// bumps accumulated. N rapid bumps → at most 1 + 1 = 2 fetches.
///
/// The first call to `markDirty()` (the priming yield from the actor stream)
/// triggers the initial fetch; subsequent calls during that fetch all
/// coalesce into a single trailing fetch.
internal actor FetchLoopCoordinator {
    private var dirty: Bool = false
    private var closed: Bool = false
    private var waiter: CheckedContinuation<Bool, Never>?

    /// Reader signal: a stream value arrived. Bumps the dirty flag and
    /// wakes the worker if it's parked.
    ///
    /// When a waiter is parked we clear `dirty` immediately and resume with
    /// `true` — the resume path is logically equivalent to the worker
    /// taking the fast path through `waitForWork`'s `if dirty` branch, so
    /// we keep the same "consumption clears the flag" invariant.
    func markDirty() {
        if let waiter {
            self.waiter = nil
            // Hand the work directly to the parked worker. dirty stays
            // false because the worker is about to consume this signal.
            dirty = false
            waiter.resume(returning: true)
        } else {
            // No parked waiter: leave the bump on the dirty flag for the
            // next call to waitForWork to pick up.
            dirty = true
        }
    }

    /// Reader signal: the stream finished. Wakes any parked waiter so the
    /// worker can exit its loop. If `dirty` was set at close time, hand
    /// that final unit of work to the worker before letting it exit on the
    /// next pass.
    func close() {
        closed = true
        if let waiter {
            self.waiter = nil
            if dirty {
                dirty = false
                waiter.resume(returning: true)
            } else {
                waiter.resume(returning: false)
            }
        }
    }

    /// Worker entry: returns `true` when there's work (dirty was set);
    /// returns `false` when the stream is closed and no more work remains.
    /// Atomically clears the dirty flag on consumption so the next call
    /// blocks until the next `markDirty()`.
    func waitForWork() async -> Bool {
        if dirty {
            dirty = false
            return true
        }
        if closed {
            return false
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.waiter = cont
            // Recheck closed/dirty after parking, in case markDirty/close
            // landed before we registered the waiter. If they did, the actor
            // serialization guarantees we'd have hit the early returns
            // above; the continuation here is only reached when both flags
            // were false at parking time.
        }
    }
}
