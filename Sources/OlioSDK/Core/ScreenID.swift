import Foundation

/// A typed identifier for a personalizable screen.
///
/// String literals are coerced automatically; declare typed constants for autocomplete:
///
///     extension ScreenID {
///         static let welcome: ScreenID = "welcome"
///         static let goalSelection: ScreenID = "goal_selection"
///     }
public struct ScreenID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
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
