import Foundation

/// A resolved variant payload for a single screen — the JSON contract between
/// dashboard and SDK.
///
/// The `slots` dictionary maps slot ids to typed content. Slot content is decoded
/// based on a `type` discriminator field at the slot level:
///
///     {
///       "screenId": "welcome",
///       "variantId": "fb_stress_v1",
///       "schemaVersion": "1.0",
///       "slots": {
///         "heading": {
///           "type": "HeadingContent",
///           "headline": "Breathe through anything"
///         },
///         "hero": {
///           "type": "MediaContent",
///           "source": { "type": "themedIllustration", "assetId": "stress_breath", "alt": "..." }
///         }
///       }
///     }
///
/// Unknown slot types are silently dropped (forward compatibility).
public struct VariantPayload: Sendable {
    public let screenId: ScreenID
    public let variantId: String
    public let schemaVersion: String
    private let slots: [SlotID: any SlotContent]

    public init(
        screenId: ScreenID,
        variantId: String,
        schemaVersion: String = "1.0",
        slots: [SlotID: any SlotContent] = [:]
    ) {
        self.screenId = screenId
        self.variantId = variantId
        self.schemaVersion = schemaVersion
        self.slots = slots
    }

    /// Look up content for a given slot id, casting to the requested type.
    /// Returns nil if the slot is absent or the type doesn't match.
    public func content<T: SlotContent>(for slotId: SlotID, as type: T.Type = T.self) -> T? {
        slots[slotId] as? T
    }

    /// All slot ids present in this payload (the keys decoded from the
    /// payload's `slots` dictionary). Order is unspecified — use a `Set`
    /// for membership checks.
    ///
    /// Useful for cross-checking a payload against a `ScreenSchema`'s
    /// `dynamicSlotKeys` when validating dev-time consistency.
    public var slotIDs: [SlotID] {
        Array(slots.keys)
    }
}

extension VariantPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case screenId, variantId, slots, schemaVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.screenId = try container.decode(ScreenID.self, forKey: .screenId)
        self.variantId = try container.decode(String.self, forKey: .variantId)
        self.schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "1.0"

        let slotsContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .slots)
        var decoded: [SlotID: any SlotContent] = [:]
        for key in slotsContainer.allKeys {
            let probe = try slotsContainer.decode(SlotTypeProbe.self, forKey: key)
            switch probe.type {
            case "HeadingContent":
                decoded[SlotID(key.stringValue)] = try slotsContainer.decode(HeadingContent.self, forKey: key)
            case "MediaContent":
                decoded[SlotID(key.stringValue)] = try slotsContainer.decode(MediaContent.self, forKey: key)
            case "ChoiceListContent":
                decoded[SlotID(key.stringValue)] = try slotsContainer.decode(ChoiceListContent.self, forKey: key)
            case "CTAContent":
                decoded[SlotID(key.stringValue)] = try slotsContainer.decode(CTAContent.self, forKey: key)
            case "CTAGroupContent":
                decoded[SlotID(key.stringValue)] = try slotsContainer.decode(CTAGroupContent.self, forKey: key)
            case "PricingContent":
                decoded[SlotID(key.stringValue)] = try slotsContainer.decode(PricingContent.self, forKey: key)
            default:
                continue // Forward compat: unknown slot types are silently dropped
            }
        }
        self.slots = decoded
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct SlotTypeProbe: Decodable {
    let type: String
}
