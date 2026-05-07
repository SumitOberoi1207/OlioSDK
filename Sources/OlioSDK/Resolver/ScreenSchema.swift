import Foundation

/// A screen's layout schema as published by the Olio dashboard.
///
/// A schema describes the *positional* layout of a personalizable screen as a
/// flat ordered list of `SchemaElement`s. Each element is either:
///
/// - `static(label:)` — iOS-side chrome (titles, captions, fixed copy). The
///   variant has no opinion on these; they're rendered by the host app.
/// - `dynamic(slot:)` — a slot the variant fills. The `slot` value is the
///   `SlotID` the variant payload's `slots` dictionary uses as a key.
///
/// ## Wire format
///
/// JSON, served from `GET /<tenant>/__schema/<screen>`:
///
///     {
///       "elements": [
///         { "type": "static",  "label": "Welcome to Calm" },
///         { "type": "dynamic", "slot":  "heading" },
///         { "type": "dynamic", "slot":  "primary_cta" }
///       ]
///     }
///
/// Schemas are optional — if a screen has no schema published, the worker
/// returns 404 and the SDK degrades silently. Schemas are public (no auth)
/// because they're descriptive, not user-specific.
public struct ScreenSchema: Sendable, Codable, Equatable {
    public let elements: [SchemaElement]

    public init(elements: [SchemaElement]) {
        self.elements = elements
    }

    /// Convenience: the slot keys (in document order) that the variant is
    /// expected to fill. Used by the SDK to compare against a variant payload
    /// and surface dev-time mismatches.
    public var dynamicSlotKeys: [String] {
        elements.compactMap { element in
            if case .dynamic(let slot) = element { return slot }
            return nil
        }
    }
}

/// One element in a `ScreenSchema`'s flat layout list.
///
/// Discriminated on the `type` JSON field:
///   - `"static"`  → `.static(label:)`
///   - `"dynamic"` → `.dynamic(slot:)`
///
/// Unknown discriminator values throw `SchemaDecodingError.unknownElementType`
/// at decode time. Callers (notably `NetworkVariantResolver.resolveSchema`)
/// catch this and degrade to `nil` — schemas are optional, never fatal.
public enum SchemaElement: Sendable, Codable, Equatable {
    case `static`(label: String)
    case dynamic(slot: String)

    private enum CodingKeys: String, CodingKey {
        case type, label, slot
    }

    private enum ElementType: String {
        case `static`
        case dynamic
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeRaw = try container.decode(String.self, forKey: .type)
        guard let type = ElementType(rawValue: typeRaw) else {
            throw SchemaDecodingError.unknownElementType(typeRaw)
        }
        switch type {
        case .static:
            let label = try container.decode(String.self, forKey: .label)
            self = .static(label: label)
        case .dynamic:
            let slot = try container.decode(String.self, forKey: .slot)
            self = .dynamic(slot: slot)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .static(let label):
            try container.encode("static", forKey: .type)
            try container.encode(label, forKey: .label)
        case .dynamic(let slot):
            try container.encode("dynamic", forKey: .type)
            try container.encode(slot, forKey: .slot)
        }
    }
}

/// Errors thrown while decoding a `ScreenSchema`.
///
/// The SDK's network resolver catches these and degrades to `nil`. Surfaced
/// publicly so test fixtures and custom resolvers can match on the cases.
public enum SchemaDecodingError: Error, Equatable {
    /// The `type` discriminator was neither `"static"` nor `"dynamic"`.
    case unknownElementType(String)
}
