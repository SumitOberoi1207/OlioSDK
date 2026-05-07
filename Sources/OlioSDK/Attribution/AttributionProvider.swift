import Foundation

/// Provides attribution context for a user's current session.
///
/// The Olio SDK is MMP-agnostic — implementations adapt different attribution
/// providers (AppsFlyer, Branch, Adjust, etc.) into a common `AttributionContext`
/// shape. The `PersonalizableScreen` container fetches attribution from the
/// configured provider before resolving variants.
///
/// ## Implementation patterns
///
/// **Real MMP integrations (AppsFlyer, Branch, Adjust):** attribution data
/// arrives asynchronously after first launch (typically 1–5 seconds). Implement
/// this protocol with a cache that's populated by the MMP's conversion-listener
/// callback, then return the cached value from `attribution()`.
///
/// **Testing:** use `MockAttributionProvider` to inject synthetic context
/// without wiring a real MMP.
///
/// **Web → app handoff:** for deferred deep links from a website (Branch
/// OneLink, AppsFlyer OneLink), populate `utmParams` from the deferred-link
/// callback. This path works fully even on iOS without ATT consent.
public protocol AttributionProvider: Sendable {
    /// Returns the attribution context for the current user.
    /// Returns nil if attribution hasn't yet resolved (first-launch race) or
    /// if no MMP is configured.
    func attribution() async -> AttributionContext?
}
