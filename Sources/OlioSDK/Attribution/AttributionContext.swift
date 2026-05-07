import Foundation

/// Attribution context for the current user — the input the Olio SDK uses to
/// resolve which variant payload to serve.
///
/// Shape is MMP-agnostic: AppsFlyer's `media_source` and Branch's `~feature`
/// both map onto `mediaSource`. The `extras` dictionary preserves anything
/// MMP-specific that doesn't fit a common field.
public struct AttributionContext: Sendable, Codable, Equatable {
    /// The acquisition channel: "facebook_ads", "tiktok", "google_uac",
    /// "organic", "web_referral", etc.
    public let mediaSource: String?

    /// The campaign name (e.g., "stress_relief_q2_2026").
    public let campaign: String?

    /// The ad set / ad group within the campaign.
    public let adSet: String?

    /// The specific creative the user clicked.
    public let creative: String?

    /// True if this is the user's first launch after install. Attribution
    /// data is most reliable on first launch; subsequent launches return
    /// cached attribution but consumers may want to differentiate.
    public let isFirstLaunch: Bool

    /// UTM parameters from web → app deferred deep links (Branch / OneLink / etc.).
    public let utmParams: [String: String]

    /// MMP-specific fields that don't fit the common shape (e.g., AppsFlyer's
    /// `af_status`, Branch's `~referring_link`).
    public let extras: [String: String]

    public init(
        mediaSource: String? = nil,
        campaign: String? = nil,
        adSet: String? = nil,
        creative: String? = nil,
        isFirstLaunch: Bool = true,
        utmParams: [String: String] = [:],
        extras: [String: String] = [:]
    ) {
        self.mediaSource = mediaSource
        self.campaign = campaign
        self.adSet = adSet
        self.creative = creative
        self.isFirstLaunch = isFirstLaunch
        self.utmParams = utmParams
        self.extras = extras
    }
}
