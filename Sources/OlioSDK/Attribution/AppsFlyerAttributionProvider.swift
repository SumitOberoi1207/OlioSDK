import Foundation

/// Stub `AttributionProvider` showing the AppsFlyer integration pattern.
///
/// **This is NOT a complete implementation.** It compiles and conforms to
/// `AttributionProvider`, but `attribution()` returns nil until you wire the
/// real AppsFlyer SDK. To complete the integration:
///
/// 1. Add the AppsFlyer SwiftPM dependency to your app:
///    ```
///    .package(url: "https://github.com/AppsFlyerSDK/AppsFlyerFramework", from: "6.14.0")
///    ```
///
/// 2. In your app's launch sequence, configure AppsFlyer before constructing
///    this provider:
///    ```swift
///    AppsFlyerLib.shared().appsFlyerDevKey = devKey
///    AppsFlyerLib.shared().appleAppID = appleAppID
///    AppsFlyerLib.shared().delegate = conversionListener
///    AppsFlyerLib.shared().start()
///    ```
///
/// 3. Implement an `AppsFlyerLibDelegate` whose
///    `onConversionDataSuccess(_ conversionInfo: [AnyHashable: Any])` callback
///    builds an `AttributionContext` from AppsFlyer's keys
///    (`media_source`, `campaign`, `af_status`, etc.) and calls
///    `provider.captureAttribution(_:)` on this provider.
///
/// 4. Handle iOS 14+ ATT consent before AppsFlyer's `start()` if you want
///    deterministic attribution; otherwise fall back to SKAdNetwork-level
///    granularity (campaign only, no creative).
///
/// Real customers ship a real adapter; the Olio SDK ships only this stub so the
/// integration shape is documented and customer code targets a stable contract.
public actor AppsFlyerAttributionProvider: AttributionProvider {
    private let devKey: String
    private let appleAppID: String
    private var cached: AttributionContext?

    public init(devKey: String, appleAppID: String) {
        self.devKey = devKey
        self.appleAppID = appleAppID
        // Real impl would configure AppsFlyerLib here and register a delegate
        // that calls `captureAttribution(_:)` once conversion data arrives.
    }

    public func attribution() async -> AttributionContext? {
        cached
    }

    /// Called by your AppsFlyer conversion-data listener once attribution
    /// arrives (typically within a few seconds of first launch).
    public func captureAttribution(_ context: AttributionContext) {
        cached = context
    }
}
