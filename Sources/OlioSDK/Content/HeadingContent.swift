import Foundation

/// Content schema for HeadingSlot — eyebrow + headline + subhead.
public struct HeadingContent: Decodable, Sendable, Equatable, SlotContent {
    public let eyebrow: String?
    public let headline: String
    public let subhead: String?
    public let alignment: Alignment
    public let emphasisStyle: EmphasisStyle

    public enum Alignment: String, Decodable, Sendable, Equatable {
        case leading
        case center
    }

    public enum EmphasisStyle: String, Decodable, Sendable, Equatable {
        case `default`
        case display
    }

    public init(
        eyebrow: String? = nil,
        headline: String,
        subhead: String? = nil,
        alignment: Alignment = .leading,
        emphasisStyle: EmphasisStyle = .default
    ) {
        self.eyebrow = eyebrow
        self.headline = headline
        self.subhead = subhead
        self.alignment = alignment
        self.emphasisStyle = emphasisStyle
    }

    private enum CodingKeys: String, CodingKey {
        case eyebrow, headline, subhead, alignment, emphasisStyle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eyebrow = try container.decodeIfPresent(String.self, forKey: .eyebrow)
        self.headline = try container.decode(String.self, forKey: .headline)
        self.subhead = try container.decodeIfPresent(String.self, forKey: .subhead)
        self.alignment = try container.decodeIfPresent(Alignment.self, forKey: .alignment) ?? .leading
        self.emphasisStyle = try container.decodeIfPresent(EmphasisStyle.self, forKey: .emphasisStyle) ?? .default
    }
}
