import Foundation

/// Content schema for ChoiceListSlot — single- or multi-select option list.
public struct ChoiceListContent: Decodable, Sendable, Equatable, SlotContent {
    public let selectionMode: SelectionMode
    public let maxSelections: Int?
    public let minSelections: Int?
    public let layout: Layout
    public let options: [ChoiceOption]

    public enum SelectionMode: String, Decodable, Sendable, Equatable {
        case single
        case multiple
    }

    public enum Layout: String, Decodable, Sendable, Equatable {
        case list
        case grid
        case chips
        case richList
    }

    public struct ChoiceOption: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let value: String
        public let label: String
        public let description: String?
        public let trailingBadge: BadgeContent?

        private enum CodingKeys: String, CodingKey {
            case id, value, label, description, trailingBadge
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.value = try container.decode(String.self, forKey: .value)
            self.label = try container.decode(String.self, forKey: .label)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.trailingBadge = try container.decodeIfPresent(BadgeContent.self, forKey: .trailingBadge)
        }
    }

    public struct BadgeContent: Decodable, Sendable, Equatable {
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
        case selectionMode, maxSelections, minSelections, layout, options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectionMode = try container.decodeIfPresent(SelectionMode.self, forKey: .selectionMode) ?? .single
        self.maxSelections = try container.decodeIfPresent(Int.self, forKey: .maxSelections)
        self.minSelections = try container.decodeIfPresent(Int.self, forKey: .minSelections)
        self.layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .list
        self.options = try container.decode([ChoiceOption].self, forKey: .options)
    }
}
