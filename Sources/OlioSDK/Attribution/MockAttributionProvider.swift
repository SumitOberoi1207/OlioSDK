import Foundation
import os

/// In-memory `AttributionProvider` for tests, demos, and previews.
///
/// Uses a synchronous, async-safe lock so that callers (typically debug menus
/// or test harnesses) can update attribution atomically without awaiting.
/// This eliminates a race where a view remounts and re-fetches variants before
/// an in-flight `setAttribution(...)` Task completes — which would silently
/// use stale attribution and request the wrong variant URL.
///
/// Drive it from a debug menu, tests, or SwiftUI previews:
///
///     let mock = MockAttributionProvider(initial: .init(
///         mediaSource: "facebook_ads",
///         campaign: "stress_relief_q2"
///     ))
///     await Olio.shared.configure(
///         resolver: BundledVariantResolver(),
///         attributionProvider: mock
///     )
///     // Later, simulate a different attribution source:
///     mock.setAttribution(.init(mediaSource: "tiktok", campaign: "creator_q2"))
public final class MockAttributionProvider: AttributionProvider, @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<AttributionContext?>

    public init(initial: AttributionContext? = nil) {
        self.storage = OSAllocatedUnfairLock(initialState: initial)
    }

    public func attribution() async -> AttributionContext? {
        storage.withLock { $0 }
    }

    /// Synchronous attribution update. No await needed at the call site.
    public func setAttribution(_ context: AttributionContext?) {
        storage.withLock { $0 = context }
    }
}
