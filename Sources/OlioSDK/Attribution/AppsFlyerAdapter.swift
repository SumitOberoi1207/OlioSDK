import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// Auto-detection adapter for the AppsFlyer iOS SDK.
///
/// Activates only when the host app has linked `AppsFlyerLib` (the AppsFlyer
/// SDK's primary class). Olio installs an internal `@objc` delegate object
/// on `AppsFlyerLib.shared()` and forwards any conversion-data callbacks into
/// `Olio.userContext.attributes`.
///
/// All interaction with AppsFlyer goes through Objective-C runtime reflection
/// — there's no compile-time symbol reference. Apps that don't link AppsFlyer
/// pay zero binary cost.
///
/// ### Reflection contract
///
/// AppsFlyer's public Objective-C surface used here:
/// - `+[AppsFlyerLib shared]`  → singleton accessor
/// - `-[AppsFlyerLib setDelegate:]`  → installs a delegate conforming to
///   `AppsFlyerLibDelegate` (informal duck-typed at runtime via
///   `-respondsToSelector:`)
/// - `-[<AppsFlyerLibDelegate> onConversionDataSuccess:]`  → callback with an
///   `NSDictionary` of attribution attributes
/// - `-[<AppsFlyerLibDelegate> onConversionDataFail:]`  → callback with an
///   `NSError` if attribution couldn't be fetched
///
/// We expose matching selectors via the `@objc` `AppsFlyerLibDelegateBridge`
/// protocol below. AppsFlyer doesn't introspect the delegate's protocol
/// conformance at the type level — it just sends selectors. So as long as our
/// delegate object responds to those selectors, AppsFlyer is happy.
struct AppsFlyerAdapter: AttributionAdapter {
    static let name = "AppsFlyer"

    static func isAvailable() -> Bool {
        NSClassFromString("AppsFlyerLib") != nil
    }

    func start(onAttribution: @Sendable @escaping ([String: String]) -> Void) {
        #if canImport(ObjectiveC)
        guard let appsFlyerClass = NSClassFromString("AppsFlyerLib") as? NSObject.Type else {
            log("AppsFlyerLib class not found at runtime; adapter inactive")
            return
        }

        // +[AppsFlyerLib shared] — class-method dispatch via NSObject.perform.
        let sharedSelector = NSSelectorFromString("shared")
        guard appsFlyerClass.responds(to: sharedSelector) else {
            log("AppsFlyerLib does not respond to +shared; cannot install delegate")
            return
        }
        let unmanaged = (appsFlyerClass as AnyObject).perform(sharedSelector)
        guard let sharedInstance = unmanaged?.takeUnretainedValue() as? NSObject else {
            log("AppsFlyerLib.shared() returned nil; adapter inactive")
            return
        }

        // -[AppsFlyerLib setDelegate:] — instance-method dispatch via perform.
        let setDelegateSelector = NSSelectorFromString("setDelegate:")
        guard sharedInstance.responds(to: setDelegateSelector) else {
            log("AppsFlyerLib instance does not respond to setDelegate:; aborting install")
            return
        }

        // Install our bridge as the delegate. Retain it on the singleton via
        // associated objects so it isn't deallocated before AppsFlyer fires
        // the conversion-data callback (which is async, ~1-3s post-launch).
        let bridge = AppsFlyerDelegateBridge(onAttribution: onAttribution)
        objc_setAssociatedObject(
            sharedInstance,
            AppsFlyerDelegateBridge.associationKey,
            bridge,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        sharedInstance.perform(setDelegateSelector, with: bridge)
        log("Installed AppsFlyer conversion-data delegate")
        #else
        log("ObjectiveC runtime unavailable; AppsFlyer adapter inactive")
        #endif
    }

    private func log(_ message: String) {
        print("[Olio] AppsFlyerAdapter: \(message)")
    }
}

#if canImport(ObjectiveC)

/// Selectors AppsFlyer's runtime sends to its `delegate`. Declared as an
/// `@objc` protocol so the bridge object's methods are exposed to the
/// Objective-C runtime.
///
/// We don't formally adopt AppsFlyer's `AppsFlyerLibDelegate` (which would
/// require a compile-time dependency); AppsFlyer dispatches via
/// `respondsToSelector:` checks, so matching selectors is sufficient.
@objc protocol AppsFlyerLibDelegateBridge: NSObjectProtocol {
    @objc func onConversionDataSuccess(_ conversionInfo: [AnyHashable: Any])
    @objc func onConversionDataFail(_ error: Error)
}

/// Internal NSObject delegate. Holds the user's `onAttribution` callback and
/// fires it whenever AppsFlyer delivers conversion data.
///
/// This class is final and `@objc`-exposed but not visible in the public API.
/// `@unchecked Sendable` because the closure is `Sendable` and there's no
/// mutable state after init.
final class AppsFlyerDelegateBridge: NSObject, AppsFlyerLibDelegateBridge, @unchecked Sendable {
    /// Associated-object key used to retain the bridge on the AppsFlyer
    /// singleton so it outlives `start(...)`.
    static let associationKey = UnsafeRawPointer(bitPattern: "OlioAppsFlyerDelegateBridge".hashValue)!

    private let onAttribution: @Sendable ([String: String]) -> Void

    init(onAttribution: @Sendable @escaping ([String: String]) -> Void) {
        self.onAttribution = onAttribution
        super.init()
    }

    @objc func onConversionDataSuccess(_ conversionInfo: [AnyHashable: Any]) {
        let normalized = AppsFlyerDelegateBridge.normalize(conversionInfo)
        guard !normalized.isEmpty else { return }
        onAttribution(normalized)
    }

    @objc func onConversionDataFail(_ error: Error) {
        // Treat fail as silent — variants will fall back to defaults (or
        // whatever the dev set on userContext). Log for diagnostics only.
        print("[Olio] AppsFlyerAdapter: conversion data unavailable (\(error.localizedDescription))")
    }

    /// Filter and stringify AppsFlyer's conversion-info payload. We keep a
    /// well-known whitelist so the wire format we send to the variant service
    /// is predictable, and convert all values to `String` (dropping anything
    /// that doesn't have a sensible string representation).
    ///
    /// Whitelist mirrors the keys the AppsFlyer iOS SDK documents on
    /// conversion data: media_source, campaign, adset, af_status, agency,
    /// partner_name. (Plus we surface `iscache` because variant-resolution
    /// strategy can differ between cached and fresh attribution.)
    ///
    /// ### `af_sub*` custom-param forwarding
    ///
    /// AppsFlyer's `af_sub1`–`af_sub5` are standard custom-param slots passed
    /// through OneLink URLs. Olio reserves:
    /// - `af_sub1` → `referral_id` — for influencer / affiliate / creator IDs
    ///   in campaigns
    /// - `af_sub2`–`af_sub5` → `sub2`–`sub5` — generic forward-compat slots
    ///
    /// Tenants set these in their AppsFlyer OneLink URL
    /// (e.g. `?af_sub1=joelovesfitness`); the SDK forwards them so dashboard
    /// matchers can target on them. Values are lowercased so matching is
    /// case-insensitive in practice (marketers paste IDs into URLs with
    /// inconsistent casing). Empty strings are dropped — we never forward
    /// `referral_id: ""` to the Worker.
    static func normalize(_ raw: [AnyHashable: Any]) -> [String: String] {
        let interestingKeys: Set<String> = [
            "media_source",
            "campaign",
            "adset",
            "af_status",
            "agency",
            "partner_name",
            "iscache"
        ]

        // AppsFlyer custom-param key → Olio normalized context key.
        // Values stored under these keys are lowercased on forward.
        let afSubMappings: [String: String] = [
            "af_sub1": "referral_id",
            "af_sub2": "sub2",
            "af_sub3": "sub3",
            "af_sub4": "sub4",
            "af_sub5": "sub5"
        ]

        var out: [String: String] = [:]
        for (anyKey, anyValue) in raw {
            guard let key = anyKey as? String else { continue }

            if interestingKeys.contains(key) {
                if let str = stringify(anyValue) {
                    out[key] = str
                }
                continue
            }

            if let destKey = afSubMappings[key] {
                if let str = stringify(anyValue) {
                    let lowered = str.lowercased()
                    if !lowered.isEmpty {
                        out[destKey] = lowered
                    }
                }
                continue
            }
        }
        return out
    }

    private static func stringify(_ value: Any) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let i = value as? Int { return String(i) }
        // NSNull — drop silently.
        if value is NSNull { return nil }
        // NSDate or any other type that has a sensible textual representation —
        // safer to forward via `String(describing:)` than to crash. Empty
        // descriptions are dropped.
        let described = String(describing: value)
        return described.isEmpty ? nil : described
    }
}

#endif
