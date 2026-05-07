import Foundation

/// A typed identifier for a slot within a personalizable screen.
///
/// String literals are coerced automatically:
///
///     HeadingSlot(id: "heading") { ... }
///
/// For autocomplete and refactoring safety, declare typed constants:
///
///     extension SlotID {
///         enum Welcome {
///             static let heading: SlotID = "heading"
///             static let hero: SlotID = "hero"
///         }
///     }
///     HeadingSlot(id: .Welcome.heading) { ... }
public struct SlotID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(stringLiteral value: String) {
        self.raw = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public var description: String { raw }
}
