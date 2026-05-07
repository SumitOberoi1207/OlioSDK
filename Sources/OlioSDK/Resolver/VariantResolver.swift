import Foundation

/// Resolves which variant payload applies for a given screen + attribution context.
///
/// In the demo phase, an implementation reads from bundled JSON. In production,
/// the implementation calls the edge variant service with the attribution + ICP
/// signals, with a local disk cache for warm starts.
///
/// The `attribution` parameter may be nil if no `AttributionProvider` is
/// configured or if attribution hasn't yet resolved (first-launch race).
/// Implementations should fall back gracefully — typically by returning the
/// default variant or nil (which causes slots to use their defaults).
public protocol VariantResolver: Sendable {
    func resolve(screen: ScreenID, attribution: AttributionContext?) async -> VariantPayload?

    /// Resolve with optional per-user signals for server-side targeting.
    ///
    /// When `userContext?.userId` is non-nil, network-backed implementations
    /// forward it to the variant service so targeting rules (percentage
    /// rollouts, country gates) can evaluate. Targeting only applies to
    /// default-variant requests; if the resolver derives an explicit variant
    /// key from `attribution` (or an override), it bypasses targeting.
    ///
    /// Default implementation delegates to `resolve(screen:attribution:)` for
    /// backwards compatibility — bundled / mock resolvers don't need to
    /// override unless they want to vary behavior on user signals.
    func resolve(
        screen: ScreenID,
        attribution: AttributionContext?,
        context: UserContext?
    ) async -> VariantPayload?

    /// Resolve the layout schema (static + dynamic elements) for a screen.
    ///
    /// Schemas are descriptive metadata published from the dashboard's
    /// "Export to dashboard" flow. They're optional — implementations that
    /// don't have a notion of schemas should return `nil` (the default).
    ///
    /// Network-backed implementations fetch from
    /// `<base>/<tenant>/__schema/<screen>`. Failure modes (404, network,
    /// decode) all degrade to `nil` so missing schemas never disrupt
    /// variant rendering.
    func resolveSchema(screen: ScreenID) async -> ScreenSchema?

    /// Resolve the PM-authored onboarding journey for the current user.
    ///
    /// Network-backed implementations fetch from
    /// `<base>/__journey/resolve` with the same context-forwarding rules as
    /// variant resolution (`?id=<userId>`, `?ctx_<key>=<value>`). The Worker
    /// returns the matched campaign's `journey` (or an empty journey if no
    /// campaign matched).
    ///
    /// Implementations that don't have a notion of journeys (bundled,
    /// in-process mocks) should return `.empty` (the default). Failure modes
    /// (404, network, decode) all degrade to `.empty` so a journey lookup
    /// never disrupts onboarding — hosts fall back to their hardcoded
    /// screen order.
    func resolveJourney(context: UserContext?) async -> OlioJourney
}

extension VariantResolver {
    public func resolve(
        screen: ScreenID,
        attribution: AttributionContext?,
        context: UserContext?
    ) async -> VariantPayload? {
        await resolve(screen: screen, attribution: attribution)
    }

    /// Default: no schema available. Bundled / mock resolvers typically don't
    /// expose schemas, so they keep this default and `PersonalizableScreen`
    /// silently skips schema validation.
    public func resolveSchema(screen: ScreenID) async -> ScreenSchema? {
        nil
    }

    /// Default: empty journey. Bundled / mock resolvers don't have a notion
    /// of journeys, so they keep this default and the host app falls back to
    /// its hardcoded screen order.
    public func resolveJourney(context: UserContext?) async -> OlioJourney {
        .empty
    }
}
