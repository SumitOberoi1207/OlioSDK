import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// Auto-detection adapter for the Adjust iOS SDK.
///
/// Activates only when the host app has linked the `Adjust` SDK class. Olio
/// observes `ADJAttributionChangedNotification` (Adjust's documented broadcast
/// name) on `NotificationCenter.default` and pulls the current
/// `ADJAttribution` synchronously when it fires. We also probe Adjust for
/// already-cached attribution at `start(...)` time — many apps integrate
/// Adjust's `ADJConfig` early in app launch and the first attribution may
/// already be available before Olio is configured.
///
/// All interaction with Adjust goes through Objective-C runtime reflection —
/// there's no compile-time symbol reference. Apps that don't link Adjust pay
/// zero binary cost.
///
/// ### Reflection contract
///
/// Adjust's public Objective-C surface used here:
/// - `+[Adjust attribution]` → returns the current `ADJAttribution *` or
///   `nil` if attribution hasn't been delivered yet.
/// - `ADJAttributionChangedNotification` (NotificationCenter name) → posted
///   whenever Adjust delivers fresh attribution. The name is a stable
///   string; we match it via `Notification.Name(rawValue:)` rather than
///   importing Adjust's header symbol.
/// - `ADJAttribution` (instance) — KVC-readable properties: `network`,
///   `campaign`, `adgroup`, `creative`, `trackerName`, `trackerToken`,
///   `clickLabel`. We use `value(forKey:)` to read them generically.
///
/// ### Why notification, not delegate
///
/// Adjust's primary delegate hook (`ADJConfig.attributionCallback` or
/// `Adjust.addAttributionListener:`) must be installed before the SDK is
/// initialized — that's the host app's responsibility, not Olio's. The
/// `ADJAttributionChangedNotification` broadcast is the public observer
/// pattern Adjust documents specifically for components that attach late.
/// It's stable across Adjust v4 and v5.
///
/// ### Caveat
///
/// Like the AppsFlyer adapter, the `available` path here is unproven from
/// inside the SDK's own tests — verifying it requires a host app with the
/// real Adjust SDK linked. The unavailable path is the only one we can
/// directly assert on, and we do.
struct AdjustAdapter: AttributionAdapter {
    static let name = "Adjust"

    static func isAvailable() -> Bool {
        // Adjust's iOS SDK exposes the `Adjust` ObjC class as the primary
        // entry point. NSClassFromString catches both the legacy ObjC
        // distribution and the newer Swift-friendly SDK (which still bridges
        // through this class).
        NSClassFromString("Adjust") != nil
    }

    func start(onAttribution: @Sendable @escaping ([String: String]) -> Void) {
        #if canImport(ObjectiveC)
        guard let adjustClass = NSClassFromString("Adjust") as? NSObject.Type else {
            log("Adjust class not found at runtime; adapter inactive")
            return
        }

        // Pull cached attribution synchronously. Adjust often has it ready
        // by the time the host calls Olio.configure(...) on later launches.
        deliverCurrentAttribution(adjustClass: adjustClass, to: onAttribution)

        // Subscribe to ADJAttributionChangedNotification. The observer holds
        // a strong reference to the closure indirectly via the bridge, and
        // we retain the bridge on the Adjust class via associated objects so
        // it isn't deallocated while NotificationCenter still has its token.
        let bridge = AdjustNotificationBridge(adjustClass: adjustClass, onAttribution: onAttribution)
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name(AdjustNotificationBridge.notificationName),
            object: nil,
            queue: nil,
            using: { [weak bridge] _ in
                bridge?.handleNotification()
            }
        )
        bridge.observerToken = token
        objc_setAssociatedObject(
            adjustClass,
            AdjustNotificationBridge.associationKey,
            bridge,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        log("Subscribed to ADJAttributionChangedNotification")
        #else
        log("ObjectiveC runtime unavailable; Adjust adapter inactive")
        #endif
    }

    #if canImport(ObjectiveC)
    /// Synchronously read `+[Adjust attribution]` and deliver it if non-nil.
    /// Used both at `start(...)` time and on each notification fire.
    fileprivate static func deliverCurrentAttribution(
        adjustClass: NSObject.Type,
        to onAttribution: @Sendable @escaping ([String: String]) -> Void
    ) {
        let attributionSelector = NSSelectorFromString("attribution")
        guard adjustClass.responds(to: attributionSelector) else {
            print("[Olio] AdjustAdapter: Adjust does not respond to +attribution; skipping read")
            return
        }
        let unmanaged = (adjustClass as AnyObject).perform(attributionSelector)
        guard let attribution = unmanaged?.takeUnretainedValue() as? NSObject else {
            // Attribution not yet available — silently skip. Subsequent
            // notification fires will retry.
            return
        }
        let normalized = AdjustNotificationBridge.normalize(attribution)
        guard !normalized.isEmpty else { return }
        onAttribution(normalized)
    }

    private func deliverCurrentAttribution(
        adjustClass: NSObject.Type,
        to onAttribution: @Sendable @escaping ([String: String]) -> Void
    ) {
        AdjustAdapter.deliverCurrentAttribution(adjustClass: adjustClass, to: onAttribution)
    }
    #endif

    private func log(_ message: String) {
        print("[Olio] AdjustAdapter: \(message)")
    }
}

#if canImport(ObjectiveC)

/// Internal bridge object that owns the NotificationCenter observer token
/// and the user's `onAttribution` callback. Held alive via associated-object
/// retention on the `Adjust` class.
///
/// `@unchecked Sendable` because the only mutable state (`observerToken`) is
/// set once on the configuring actor and read from the notification queue;
/// `NSObjectProtocol` tokens are themselves thread-safe to retain/release.
final class AdjustNotificationBridge: NSObject, @unchecked Sendable {
    /// The exact NotificationCenter name Adjust posts when attribution
    /// changes. Documented in Adjust's iOS SDK README (both v4 and v5).
    static let notificationName = "ADJAttributionChangedNotification"

    /// Associated-object key used to retain the bridge on the Adjust class so
    /// it outlives `start(...)`.
    static let associationKey = UnsafeRawPointer(bitPattern: "OlioAdjustNotificationBridge".hashValue)!

    private let adjustClass: NSObject.Type
    private let onAttribution: @Sendable ([String: String]) -> Void

    /// Held so the observer can be torn down if the bridge is ever removed.
    /// Currently we don't proactively unsubscribe (the bridge lives for the
    /// app's lifetime), but the token retention keeps NotificationCenter's
    /// internal weak ref valid.
    var observerToken: NSObjectProtocol?

    init(
        adjustClass: NSObject.Type,
        onAttribution: @Sendable @escaping ([String: String]) -> Void
    ) {
        self.adjustClass = adjustClass
        self.onAttribution = onAttribution
        super.init()
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func handleNotification() {
        // Re-read current attribution from Adjust on each notification
        // rather than parsing notification.userInfo — Adjust's userInfo
        // shape has varied across versions; +[Adjust attribution] is the
        // documented stable accessor.
        AdjustAdapter.deliverCurrentAttribution(adjustClass: adjustClass, to: onAttribution)
    }

    /// KVC-read the documented `ADJAttribution` properties off the live
    /// instance, lowercase the values, and map them onto Olio's
    /// normalized context vocabulary.
    ///
    /// ### Mapping decisions
    ///
    /// - `network` → `media_source` — Adjust's `network` field is the
    ///   conceptual analog of AppsFlyer's `media_source`. We **do not**
    ///   remap Adjust's values onto the AppsFlyer-flavored catalog the
    ///   dashboard ships with by default (e.g. `facebook_ads`,
    ///   `googleadwords_int`). Adjust surfaces strings like
    ///   `"Facebook Installs"` and `"Google Ads ACI"`. Tenants on Adjust
    ///   should target on Adjust's actual values; remapping would silently
    ///   drop information.
    /// - `campaign`, `adgroup`, `creative` → identical key names. Tenant-
    ///   specific so we just lowercase and pass through.
    /// - `trackerName` → `tracker`. Adjust-specific concept, useful for
    ///   power users targeting on the canonical tracker label.
    /// - `clickLabel`: skipped. Click-time custom label, less useful for
    ///   variant targeting and noisy.
    /// - `trackerToken`: skipped. Internal id, redundant with `trackerName`
    ///   for the dashboard's purposes.
    static func normalize(_ attribution: NSObject) -> [String: String] {
        // Adjust property name → Olio context key.
        let mapping: [(String, String)] = [
            ("network", "media_source"),
            ("campaign", "campaign"),
            ("adgroup", "adgroup"),
            ("creative", "creative"),
            ("trackerName", "tracker")
        ]

        var out: [String: String] = [:]
        for (sourceKey, destKey) in mapping {
            guard attribution.responds(to: NSSelectorFromString(sourceKey)) else { continue }
            let raw = attribution.value(forKey: sourceKey)
            if let str = stringify(raw) {
                out[destKey] = str.lowercased()
            }
        }
        return out
    }

    private static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        if let i = value as? Int { return String(i) }
        return nil
    }
}

#endif
