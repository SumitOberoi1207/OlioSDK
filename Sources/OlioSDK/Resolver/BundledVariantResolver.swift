import Foundation

/// Demo-phase resolver that reads variant payloads from JSON files in the app bundle.
///
/// Variant files are named `<screenId>.<variantId>.json` (or `<screenId>.json` for
/// the default variant) in a subdirectory you specify. The variant key is derived
/// from the supplied `AttributionContext` via a customizable mapping function;
/// for QA/debug overrides, call `setActiveVariantOverride(_:)`.
///
/// Example bundle layout:
///
///     TryolioVariants/
///       welcome.json                   ← default
///       welcome.fb_stress.json         ← stress campaign variant
///       welcome.fb_sleep.json          ← sleep campaign variant
public actor BundledVariantResolver: VariantResolver {
    private let bundle: Bundle
    private let directoryName: String?
    private let mapper: AttributionMapping.Mapper
    private var override: String?
    private var cache: [String: VariantPayload] = [:]

    public init(
        bundle: Bundle = .main,
        directoryName: String? = "TryolioVariants",
        attributionMapper: @escaping AttributionMapping.Mapper = AttributionMapping.defaultMapper
    ) {
        self.bundle = bundle
        self.directoryName = directoryName
        self.mapper = attributionMapper
    }

    /// Force a specific variant id, bypassing the attribution-based mapping.
    /// Useful for QA, debug menus, and demos.
    public func setActiveVariantOverride(_ variantId: String?) {
        self.override = variantId
    }

    public func resolve(screen: ScreenID, attribution: AttributionContext?) async -> VariantPayload? {
        let variantKey = override ?? attribution.flatMap(mapper)
        let cacheKey = "\(screen.raw)|\(variantKey ?? "_default")"

        if let cached = cache[cacheKey] {
            return cached
        }

        let resourceName: String = {
            if let variantKey = variantKey {
                return "\(screen.raw).\(variantKey)"
            } else {
                return screen.raw
            }
        }()

        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: directoryName
        ) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(VariantPayload.self, from: data)
            cache[cacheKey] = payload
            return payload
        } catch {
            // Fail-open: log and return nil so slots fall back to defaults.
            print("[Olio] Failed to decode variant \(resourceName).json: \(error)")
            return nil
        }
    }

}
