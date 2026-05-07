import Foundation

/// Functions that map an `AttributionContext` to a variant key string.
///
/// The variant key is what `BundledVariantResolver` and `NetworkVariantResolver`
/// use to identify which payload to fetch — both `<screen>.<variantKey>.json`
/// for bundled resources and `<base>/<screen>.<variantKey>.json` for the network.
///
/// Customers can supply their own mapper at resolver init time. The default
/// mapper covers a couple of common consumer-mobile patterns to make the
/// initial demo work; production deployments typically override or move this
/// logic server-side.
public enum AttributionMapping {
    public typealias Mapper = @Sendable (AttributionContext) -> String?

    /// Default attribution → variant-key mapping. Recognizes Facebook stress
    /// and sleep campaigns as a starter set; everything else returns nil
    /// (which falls back to the default variant or screen defaults).
    public static let defaultMapper: Mapper = { attribution in
        guard let mediaSource = attribution.mediaSource else { return nil }

        if mediaSource == "facebook_ads" {
            if let campaign = attribution.campaign {
                if campaign.localizedCaseInsensitiveContains("stress") {
                    return "fb_stress"
                }
                if campaign.localizedCaseInsensitiveContains("sleep") {
                    return "fb_sleep"
                }
            }
        }
        return nil
    }
}
