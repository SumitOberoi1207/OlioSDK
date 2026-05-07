import Foundation

/// Content schema for CTASlot — a single primary action button.
public struct CTAContent: Decodable, Sendable, Equatable, SlotContent {
    public let label: String
    public let style: Style
    public let action: Action
    public let enabled: Bool
    public let loadingLabel: String?

    public enum Style: String, Decodable, Sendable, Equatable {
        case primary
        case secondary
        case tertiary
        case destructive
    }

    private enum CodingKeys: String, CodingKey {
        case label, style, action, enabled, loadingLabel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        self.style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .primary
        self.action = try container.decode(Action.self, forKey: .action)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.loadingLabel = try container.decodeIfPresent(String.self, forKey: .loadingLabel)
    }
}
