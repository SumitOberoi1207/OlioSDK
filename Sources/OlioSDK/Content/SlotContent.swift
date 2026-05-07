import Foundation

/// Marker protocol for typed slot content.
///
/// Each Tier 1 content type conforms — `HeadingContent`, `MediaContent`,
/// `ChoiceListContent`, `CTAContent`, `CTAGroupContent`. Used by `VariantPayload`
/// to store heterogeneous slot contents in a typed dictionary.
public protocol SlotContent: Sendable {}
