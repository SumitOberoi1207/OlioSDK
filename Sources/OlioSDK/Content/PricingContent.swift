import Foundation

/// Content schema for PricingSlot — plan tier selection on paywall screens.
///
/// The plan list ordering, default selection, badge text, and strikethrough
/// pricing are all variant-controlled. Product IDs reference real App Store /
/// RevenueCat catalog entries; the slot exposes pricing display, not actuals.
public struct PricingContent: Decodable, Sendable, Equatable, SlotContent {
    public let plans: [Plan]
    public let defaultSelectedId: String?
    public let showFreeTrialToggle: Bool
    public let freeTrialDescription: String?

    public struct Plan: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let productId: String
        public let name: String
        public let primaryPrice: String
        public let secondaryPrice: String?
        public let strikethroughPrice: String?
        public let badge: Badge?
        public let isHighlighted: Bool

        public struct Badge: Decodable, Sendable, Equatable {
            public let text: String
            public let style: Style

            public enum Style: String, Decodable, Sendable, Equatable {
                case neutral
                case promo
                case warning
            }

            private enum CodingKeys: String, CodingKey {
                case text, style
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.text = try container.decode(String.self, forKey: .text)
                self.style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .neutral
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id, productId, name, primaryPrice, secondaryPrice, strikethroughPrice, badge, isHighlighted
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.productId = try container.decode(String.self, forKey: .productId)
            self.name = try container.decode(String.self, forKey: .name)
            self.primaryPrice = try container.decode(String.self, forKey: .primaryPrice)
            self.secondaryPrice = try container.decodeIfPresent(String.self, forKey: .secondaryPrice)
            self.strikethroughPrice = try container.decodeIfPresent(String.self, forKey: .strikethroughPrice)
            self.badge = try container.decodeIfPresent(Badge.self, forKey: .badge)
            self.isHighlighted = try container.decodeIfPresent(Bool.self, forKey: .isHighlighted) ?? false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case plans, defaultSelectedId, showFreeTrialToggle, freeTrialDescription
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.plans = try container.decode([Plan].self, forKey: .plans)
        self.defaultSelectedId = try container.decodeIfPresent(String.self, forKey: .defaultSelectedId)
        self.showFreeTrialToggle = try container.decodeIfPresent(Bool.self, forKey: .showFreeTrialToggle) ?? false
        self.freeTrialDescription = try container.decodeIfPresent(String.self, forKey: .freeTrialDescription)
    }
}
