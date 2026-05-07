import Foundation

/// Internal protocol for runtime-detected MMP (Mobile Measurement Partner)
/// adapters. Each MMP we want to support gets one conforming type.
///
/// Why this exists separately from `AttributionProvider`:
/// - `AttributionProvider` is the **public**, customer-facing protocol the host
///   app implements (or supplies an instance of) when wiring attribution
///   manually. It's pull-based: `PersonalizableScreen` asks for the current
///   `AttributionContext` at variant-resolve time.
/// - `AttributionAdapter` is the **internal** auto-detection contract. The SDK
///   ships one adapter per supported MMP. At launch the SDK probes each adapter
///   in priority order; the first whose corresponding MMP SDK is linked into
///   the app bundle gets activated. The adapter then push-publishes attribution
///   into `Olio.userContext.attributes` whenever its MMP delivers data.
///
/// Adapters MUST NOT add a Swift Package dependency on the corresponding MMP
/// SDK — they interact via Objective-C runtime reflection
/// (`NSClassFromString`, selector dispatch). Apps that don't link the MMP pay
/// zero binary cost; `isAvailable()` returns false and the adapter is skipped.
///
/// Adapters MUST be defensive: `start(...)` must never throw, never crash, and
/// never block. Selector-dispatch failures should be logged with the
/// `[Olio]` prefix and swallowed.
protocol AttributionAdapter: Sendable {
    /// Human-readable name of the underlying MMP, e.g. `"AppsFlyer"`. Surfaces
    /// in detection log messages and (eventually) telemetry.
    static var name: String { get }

    /// Cheap runtime check: returns `true` iff the underlying MMP SDK is linked
    /// into the running app bundle. Implementations typically just call
    /// `NSClassFromString(...)` against the MMP's primary class.
    static func isAvailable() -> Bool

    /// No-arg initializer so the orchestrator can construct adapters
    /// generically through their metatype. Adapters that need configuration
    /// should pull it from the host environment at `start(...)` time, not at
    /// init time — they're constructed by the SDK, not the host.
    init()

    /// Subscribe to attribution data from the underlying MMP. The adapter
    /// invokes `onAttribution` zero or more times — once when the MMP delivers
    /// the initial conversion data, plus any subsequent updates the MMP emits
    /// (some emit cached data immediately on every relaunch, others only on
    /// change).
    ///
    /// The closure is called with already-stringified key/value pairs. Olio
    /// merges them into `Olio.userContext.attributes` using a
    /// dev-attributes-win policy.
    func start(onAttribution: @Sendable @escaping ([String: String]) -> Void)
}
