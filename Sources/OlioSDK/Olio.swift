import Foundation

/// Top-level configuration entry for the Olio SDK.
///
/// At app launch, configure with a resolver and (optionally) an attribution
/// provider. For the demo phase, use `BundledVariantResolver` + a mock or
/// stub attribution provider:
///
///     @main
///     struct DemoApp: App {
///         init() {
///             Task {
///                 await Olio.shared.configure(
///                     resolver: BundledVariantResolver(),
///                     attributionProvider: MockAttributionProvider()
///                 )
///             }
///         }
///         // ...
///     }
///
/// In production, swap in a network-backed resolver and a real MMP-backed
/// attribution provider (AppsFlyer, Branch, Adjust, etc.).
///
/// To enable server-side targeting (percentage rollouts, country gates),
/// also call `setUserContext(_:)` once per session with a stable user
/// identifier:
///
///     await Olio.shared.setUserContext(UserContext(userId: installID))
///
/// ### MMP attribution auto-detection
///
/// `configure(...)` defaults to `autoDetectMMP: true`, which probes for
/// supported MMP SDKs (AppsFlyer first; Adjust skeleton) at runtime via
/// `NSClassFromString`. If a probe succeeds, Olio installs an internal
/// delegate on the MMP and merges any conversion data it delivers into
/// `userContext.attributes`. Host-set attributes always win on key conflicts.
///
/// **First-screen race:** MMP attribution typically arrives 1–3s after launch
/// (network round-trip). Variants resolved before then won't include MMP
/// attribution; subsequent screen mounts will. `PersonalizableScreen`
/// subscribes to `userContextChanges()` and re-resolves its variant when the
/// context updates — so the first screen mounted at app launch (typically
/// Welcome) picks up the targeted variant once MMP attribution arrives.
public actor Olio {
    public static let shared = Olio()

    private(set) public var resolver: (any VariantResolver)?
    private(set) public var attributionProvider: (any AttributionProvider)?
    private(set) public var userContext: UserContext?

    /// Names of MMP adapters that have been activated this session. Useful
    /// for diagnostic logging and tests. Empty when auto-detection finds
    /// nothing or is disabled.
    private(set) public var activatedMMPAdapters: [String] = []

    /// MMP adapters checked in priority order. First one whose
    /// `isAvailable()` returns true wins; the rest are skipped. Static lookup
    /// keeps the list discoverable in one place when adding new adapters.
    private static let registeredAdapters: [any AttributionAdapter.Type] = [
        AppsFlyerAdapter.self,
        AdjustAdapter.self
    ]

    /// Active continuations broadcasting `userContext` changes. Each call to
    /// `userContextChanges()` registers its own continuation, keyed by a
    /// monotonic id so we can drop it when the consumer stops iterating
    /// (`.onTermination`). Storing per-subscriber means each
    /// `PersonalizableScreen` gets its own independent stream — no fan-out
    /// queue contention or back-pressure across screens.
    private var contextChangeContinuations: [Int: AsyncStream<UserContext?>.Continuation] = [:]
    private var nextContinuationID: Int = 0

    /// Cached journey lookup. The journey only changes when a PM publishes a
    /// new campaign on the dashboard (rare, out-of-band), so caching for the
    /// lifetime of the Olio instance is safe — call `invalidateJourney()` to
    /// force a re-fetch (e.g. after a debug attribution change). Bundled-mode
    /// SDKs cache `.empty` once and never re-fetch.
    private var cachedJourney: OlioJourney?

    private init() {}

    /// Configure the SDK with a resolver and optional attribution provider.
    ///
    /// - Parameters:
    ///   - resolver: variant resolver (bundled, network-backed, or custom).
    ///   - attributionProvider: optional pull-based attribution provider for
    ///     manually-wired MMPs. Independent of `autoDetectMMP` — both can
    ///     coexist.
    ///   - autoDetectMMP: if `true` (default), the SDK probes for supported
    ///     MMP SDKs at runtime and auto-forwards their attribution data into
    ///     `userContext.attributes`. Pass `false` to opt out (e.g. when the
    ///     host app prefers to wire attribution manually via
    ///     `setUserContext(...)`).
    ///   - autoCollectDeviceContext: if `true` (default), the SDK collects
    ///     `device_type`, `app_version`, and `days_since_install` from the
    ///     runtime/Bundle/UserDefaults and merges them into
    ///     `userContext.attributes` so the Worker's v2 matchers fire without
    ///     any iOS-side wiring. Pass `false` to opt out entirely (the keys
    ///     won't be set by the SDK; dev-set values still flow through). The
    ///     full merge precedence is `defaults < MMP < dev-set`.
    public func configure(
        resolver: any VariantResolver,
        attributionProvider: (any AttributionProvider)? = nil,
        autoDetectMMP: Bool = true,
        autoCollectDeviceContext: Bool = true
    ) {
        self.resolver = resolver
        self.attributionProvider = attributionProvider

        // Apply defaults first so the precedence chain is `defaults < MMP <
        // dev-set`. Dev-set attributes already on `userContext` win because
        // `mergingDefaultAttributes` overlays existing values on top of the
        // defaults map.
        if autoCollectDeviceContext {
            applyDefaultDeviceContext()
        }

        if autoDetectMMP {
            detectMMPAttribution()
        }
    }

    /// Provide per-user signals (currently a stable user id) so server-side
    /// targeting rules can evaluate. Pass `nil` to clear.
    ///
    /// Targeting only applies to default-variant requests; explicit
    /// `variantKey` paths skip targeting regardless of the user context.
    public func setUserContext(_ context: UserContext?) {
        updateUserContext(context)
    }

    /// Subscribe to `userContext` changes. The returned stream yields the
    /// **current** value immediately, then yields again on every subsequent
    /// mutation (host call to `setUserContext`, MMP attribution merge, or
    /// default-context collection).
    ///
    /// Cancel by stopping iteration — the actor drops the continuation
    /// automatically (see `.onTermination`).
    ///
    /// `PersonalizableScreen` consumes this stream to re-fetch variants when
    /// MMP attribution arrives mid-session. Most apps never need to call this
    /// directly.
    public func userContextChanges() -> AsyncStream<UserContext?> {
        let id = nextContinuationID
        nextContinuationID += 1
        let initialValue = userContext
        return AsyncStream<UserContext?> { continuation in
            // Prime with the current value so subscribers immediately see
            // whatever state exists at subscription time. Avoids a race where
            // the subscriber registered just after a mutation and would
            // otherwise sit idle until the *next* change.
            continuation.yield(initialValue)
            self.registerContinuation(continuation, id: id)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unregisterContinuation(id: id) }
            }
        }
    }

    /// Mutate `userContext` and broadcast to all live subscribers. Centralizes
    /// the bookkeeping so every mutation path (host setter, MMP merge, default
    /// collection) hits the same broadcast.
    private func updateUserContext(_ context: UserContext?) {
        self.userContext = context
        for continuation in contextChangeContinuations.values {
            continuation.yield(context)
        }
    }

    private func registerContinuation(
        _ continuation: AsyncStream<UserContext?>.Continuation,
        id: Int
    ) {
        contextChangeContinuations[id] = continuation
    }

    private func unregisterContinuation(id: Int) {
        contextChangeContinuations.removeValue(forKey: id)
    }

    /// Fetch the layout schema for a screen, if one is published.
    ///
    /// Useful for advanced integrations (dev tooling, in-app schema
    /// inspectors). Returns `nil` if no resolver is configured, no schema
    /// exists, or the resolver doesn't support schemas (e.g. the bundled
    /// resolver). `PersonalizableScreen` consumes schemas internally for
    /// dev-time validation — most apps never need to call this directly.
    public func schema(for screen: ScreenID) async -> ScreenSchema? {
        guard let resolver else { return nil }
        return await resolver.resolveSchema(screen: screen)
    }

    /// Resolve the PM-authored onboarding journey for the current user.
    ///
    /// Returns the matched campaign's journey (ordered screen list + skip
    /// flags) or `.empty` if no campaign matched, no resolver is configured,
    /// the resolver doesn't support journeys (bundled mode), or the lookup
    /// failed. Hosts should treat `.empty` as the "no override" sentinel and
    /// fall back to their hardcoded screen order.
    ///
    /// The result is cached for the lifetime of this Olio instance — the
    /// journey only changes when a PM publishes a new campaign on the
    /// dashboard, which is rare and out-of-band. Call `invalidateJourney()`
    /// to force a re-fetch (e.g. after a debug attribution change).
    public func journey() async -> OlioJourney {
        if let cached = cachedJourney { return cached }
        guard let resolver else { return .empty }
        let resolved = await resolver.resolveJourney(context: userContext)
        cachedJourney = resolved
        return resolved
    }

    /// Forces the next `journey()` call to re-fetch from the resolver.
    /// Useful after debug context changes (e.g. swapping the active variant
    /// in the demo's debug picker) or when a PM has just published a new
    /// campaign and you want the live app to pick it up without a relaunch.
    public func invalidateJourney() {
        cachedJourney = nil
    }

    /// Pre-fetch the variant payload for `screen` so the next
    /// `PersonalizableScreen(id:)` mount finds it warm in URLCache and
    /// doesn't flash defaults during a network roundtrip. Safe to call from
    /// app startup; returns when the fetch completes (or fails — failures
    /// are silent because the payload-cache warmup is best-effort).
    public func prefetchPayload(for screen: ScreenID) async {
        guard let resolver else { return }
        let attribution = await attributionProvider?.attribution()
        _ = await resolver.resolve(
            screen: screen,
            attribution: attribution,
            context: userContext
        )
    }

    /// Pre-fetch every variant payload referenced by the resolved journey, in
    /// parallel. The host doesn't need to know which screens it ships — the
    /// SDK reads the journey it just resolved and warms URLCache for each.
    /// No-op if the journey is empty (no campaign matched, bundled mode, or
    /// network failure). Best-effort — individual fetch failures are
    /// silently tolerated.
    public func prefetchJourney() async {
        let resolved = await journey()
        guard !resolved.order.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for screen in resolved.order where !resolved.skip.contains(screen) {
                let id = ScreenID(screen)
                group.addTask {
                    await self.prefetchPayload(for: id)
                }
            }
        }
    }

    // MARK: - Default device-context collection

    /// Collect `device_type` / `app_version` / `days_since_install` from the
    /// runtime and overlay them under any existing `userContext.attributes`.
    /// Dev-set keys win on conflict — defaults only fill in gaps.
    ///
    /// If no `userContext` exists yet (the dev hasn't called
    /// `setUserContext(...)`), we synthesize a `UserContext(userId: nil,
    /// attributes: defaults)` so the defaults still propagate to the resolver.
    /// The resolver only requires `userId` for percentage/country targeting,
    /// not for `ctx_*` attribute forwarding.
    ///
    /// Always defensive: collection failures (missing Bundle keys, unrecognized
    /// `userInterfaceIdiom`, UserDefaults misbehavior) result in absent keys
    /// rather than crashes — the contract is "auto-collection must NEVER throw
    /// or crash".
    private func applyDefaultDeviceContext() {
        let defaults = DefaultContextProvider.collect()
        guard !defaults.isEmpty else { return }
        if let existing = userContext {
            updateUserContext(existing.mergingDefaultAttributes(defaults))
        } else {
            updateUserContext(UserContext(userId: nil, attributes: defaults))
        }
    }

    // MARK: - MMP auto-detection

    /// Iterate registered MMP adapters in priority order. Activate the first
    /// whose `isAvailable()` returns true; ignore the rest. Each activated
    /// adapter receives a callback that funnels back into
    /// `mergeMMPAttribution(_:)` on this actor.
    ///
    /// All probe failures are swallowed — auto-detection must never throw,
    /// crash, or hang the host app.
    private func detectMMPAttribution() {
        for adapterType in Self.registeredAdapters {
            guard adapterType.isAvailable() else { continue }
            print("[Olio] Detected MMP: \(adapterType.name)")
            activatedMMPAdapters.append(adapterType.name)
            let adapter = adapterType.init()
            adapter.start { [weak self] attrs in
                guard let self else { return }
                Task { await self.mergeMMPAttribution(attrs) }
            }
            // First match wins. Multi-MMP scenarios are rare and would conflict.
            return
        }
    }

    /// Merge MMP-supplied attribution into the existing `userContext`. Host-set
    /// attributes (anything the dev passed via `setUserContext(...)`) take
    /// precedence on key conflicts; MMP attributes only fill in gaps.
    ///
    /// If `userContext` is nil (the dev never called `setUserContext`), we
    /// synthesize a `UserContext(userId: nil, attributes: mmpAttrs)` so the
    /// MMP data still propagates to the resolver — the resolver only requires
    /// `userId` for percentage/country targeting, not for ctx_* attribute
    /// forwarding.
    private func mergeMMPAttribution(_ mmpAttrs: [String: String]) {
        guard !mmpAttrs.isEmpty else { return }
        if let existing = userContext {
            updateUserContext(existing.mergingMMPAttributes(mmpAttrs))
        } else {
            updateUserContext(UserContext(userId: nil, attributes: mmpAttrs))
        }
    }
}

