import SwiftUI

private struct VariantPayloadKey: EnvironmentKey {
    static let defaultValue: VariantPayload? = nil
}

extension EnvironmentValues {
    /// The variant payload for the enclosing `PersonalizableScreen`, or nil if
    /// no variant resolved (network failure, no matching variant, defaults-only mode).
    public var variantPayload: VariantPayload? {
        get { self[VariantPayloadKey.self] }
        set { self[VariantPayloadKey.self] = newValue }
    }
}
