import Foundation

/// Content schema for CTAGroupSlot — primary + optional secondary/tertiary CTAs.
public struct CTAGroupContent: Decodable, Sendable, Equatable, SlotContent {
    public let primary: CTAContent
    public let secondary: CTAContent?
    public let tertiary: CTAContent?
    public let layout: Layout

    public enum Layout: String, Decodable, Sendable, Equatable {
        case stacked
        case horizontal
    }

    private enum CodingKeys: String, CodingKey {
        case primary, secondary, tertiary, layout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try container.decode(CTAContent.self, forKey: .primary)
        self.secondary = try container.decodeIfPresent(CTAContent.self, forKey: .secondary)
        self.tertiary = try container.decodeIfPresent(CTAContent.self, forKey: .tertiary)
        self.layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .stacked
    }
}
