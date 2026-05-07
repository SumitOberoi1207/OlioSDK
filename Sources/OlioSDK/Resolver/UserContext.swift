import Foundation

/// Per-user signals the SDK forwards to the variant service so it can run
/// server-side targeting rules (percentage rollouts, country gates, cohort
/// matching, etc.).
///
/// Forwarding is wire-level: when a `UserContext` is supplied, the SDK appends
/// `?id=<userId>` to the default-variant request URL. The Cloudflare Worker
/// reads that `id`, hashes it (FNV-1a mod 100) for percentage rules, and uses
/// the `Cf-IPCountry` request header for country rules. On a rule match, the
/// Worker returns the targeted variant body and tags the response with
/// `X-Tryolio-Targeting-Rule: <ruleId>`. On no match, it falls through to the
/// default file (or 404).
///
/// Targeting only kicks in for **default-variant** requests
/// (`<screen>.json`). Explicit variant fetches
/// (`<screen>.<variantKey>.json`) are deterministic and skip targeting.
///
/// `attributes` is forwarded as `?ctx_<key>=<value>` query params on
/// default-variant requests (sorted alphabetically by key for deterministic
/// URLs). Empty-string values are skipped silently. Like `?id`, attributes are
/// only sent on default-variant fetches — explicit-variant URLs bypass them.
///
/// Pass `nil` (or an instance with `userId == nil`) to opt out of targeting:
/// the request goes out without the `id` query param and the Worker returns
/// the static default file.
public struct UserContext: Sendable, Equatable {
    /// Stable per-user identifier used for percentage-based targeting. Treat
    /// it like an analytics/install id, not auth — it's hashed server-side.
    public let userId: String?

    /// Forward-compatible bag for custom signals the Worker may consume in
    /// future rule types. Not appended to the URL today.
    public let attributes: [String: String]

    public init(userId: String?, attributes: [String: String] = [:]) {
        self.userId = userId
        self.attributes = attributes
    }

    /// Returns a copy of `self` with `mmpAttributes` overlaid into
    /// `attributes`, using a **dev-attributes-win** merge policy: any key
    /// already present on `self.attributes` (i.e. set by the host app) keeps
    /// its existing value. Keys present only in `mmpAttributes` are added.
    ///
    /// Used by the runtime MMP auto-detection orchestrator
    /// (`Olio.detectMMPAttribution`) to fold MMP-supplied attribution into
    /// the user context without clobbering anything the dev set explicitly.
    /// The host app is the authoritative source — MMPs only fill in gaps.
    func mergingMMPAttributes(_ mmpAttributes: [String: String]) -> UserContext {
        var merged = mmpAttributes
        for (key, value) in self.attributes {
            merged[key] = value
        }
        return UserContext(userId: self.userId, attributes: merged)
    }

    /// Returns a copy of `self` with `defaultAttributes` underlaid behind
    /// `attributes`, using a **dev-attributes-win** merge policy. Keys already
    /// on `self.attributes` keep their existing value; keys present only in
    /// `defaultAttributes` are added.
    ///
    /// Identical merge semantics to `mergingMMPAttributes(_:)` — the only
    /// difference is the layer the defaults sit on. The full merge precedence
    /// the SDK enforces at `configure(...)` time is:
    ///
    ///     defaults < MMP < dev-set
    ///
    /// In practice that means defaults are applied first (lowest priority),
    /// then MMP overlays them via `mergingMMPAttributes`, then dev-set values
    /// (already on `self.attributes` by the time MMP merging happens) win
    /// over both.
    func mergingDefaultAttributes(_ defaultAttributes: [String: String]) -> UserContext {
        var merged = defaultAttributes
        for (key, value) in self.attributes {
            merged[key] = value
        }
        return UserContext(userId: self.userId, attributes: merged)
    }
}
