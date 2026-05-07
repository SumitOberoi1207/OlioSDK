import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Collects default device-context attributes that the Olio Worker's v2
/// matchers consume (`device_type`, `app_version`, `days_since_install`).
///
/// Designed as a pure function: every call recomputes from the live runtime,
/// the host's `Bundle.main`, and the persisted first-launch timestamp in
/// `UserDefaults`. There's no in-memory caching at the type level — repeated
/// calls within the same launch will see identical results because the inputs
/// don't change.
///
/// ### Failure semantics
///
/// Auto-collection must NEVER throw or crash. Every individual signal is
/// collected behind a defensive guard:
/// - Unrecognized `userInterfaceIdiom` → `device_type` key omitted.
/// - Missing `CFBundleShortVersionString` (or empty string) → `app_version`
///   key omitted.
/// - `UserDefaults` read/write failure → `days_since_install` key omitted.
///
/// On any failure path the missing key is simply absent from the returned
/// dictionary; the host app is never informed and never crashes.
///
/// ### UserDefaults persistence
///
/// `days_since_install` is computed against the timestamp persisted under
/// `Self.installDateUserDefaultsKey` (`"com.olio.installDate"`). On the very
/// first call (no stored timestamp), the provider writes `Date()` and returns
/// `"0"`. On subsequent calls it reads the stored timestamp and floors the
/// elapsed-days delta. Tests can inject an alternate `UserDefaults` instance
/// to avoid poisoning the shared `.standard` suite.
struct DefaultContextProvider: Sendable {

    /// `UserDefaults` key used to persist the first-launch timestamp. Tests
    /// assert on this constant; production callers shouldn't reference it.
    static let installDateUserDefaultsKey = "com.olio.installDate"

    /// Collects device-context attributes from the live runtime against
    /// `UserDefaults.standard`. Convenience entry point used by the Olio
    /// actor at `configure(...)` time.
    static func collect() -> [String: String] {
        collect(userDefaults: .standard, bundle: .main, now: Date())
    }

    /// Collects device-context attributes against an injected `UserDefaults`
    /// and `Bundle`. The `now` parameter exists so tests can deterministically
    /// compute `days_since_install` against a seeded first-launch timestamp
    /// without sleeping. Production callers use the parameterless overload
    /// above.
    static func collect(
        userDefaults: UserDefaults,
        bundle: Bundle = .main,
        now: Date = Date()
    ) -> [String: String] {
        var attrs: [String: String] = [:]

        if let deviceType = currentDeviceType() {
            attrs["device_type"] = deviceType
        }

        if let appVersion = currentAppVersion(bundle: bundle) {
            attrs["app_version"] = appVersion
        }

        if let daysSinceInstall = currentDaysSinceInstall(userDefaults: userDefaults, now: now) {
            attrs["days_since_install"] = daysSinceInstall
        }

        return attrs
    }

    // MARK: - device_type

    /// Returns a lowercased device-class string the Worker's v2 matcher
    /// expects (`"iphone"`, `"ipad"`, `"mac"`, `"tv"`, `"vision"`), or `nil`
    /// when the platform exposes no sensible match target (`.carPlay`,
    /// `.unspecified`, native macOS without UIKit on legacy SDKs, watchOS).
    private static func currentDeviceType() -> String? {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        // Native AppKit-only macOS: no `UIDevice`, but the Worker still wants
        // a `device_type` so country/cohort rules can target Mac users.
        return "mac"
        #elseif canImport(UIKit) && !os(watchOS)
        // iOS, iPadOS, tvOS, visionOS, and Mac Catalyst all expose
        // `UIDevice.current.userInterfaceIdiom`.
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        case .mac:
            // Mac Catalyst reports `.mac`.
            return "mac"
        case .tv:
            return "tv"
        case .vision:
            return "vision"
        case .carPlay, .unspecified:
            // CarPlay and unspecified aren't sensible match targets — omit
            // the key so the matcher treats it as "no signal".
            return nil
        @unknown default:
            // A future idiom we don't recognize — treat as no signal.
            return nil
        }
        #else
        // watchOS or other platforms with no `UIDevice` — omit the key.
        return nil
        #endif
    }

    // MARK: - app_version

    /// Returns the user-visible marketing version string (e.g. `"2.5.0"`) from
    /// `CFBundleShortVersionString`. Returns `nil` when the key is absent or
    /// empty so the matcher key is omitted entirely (no fabricated value).
    private static func currentAppVersion(bundle: Bundle) -> String? {
        guard
            let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - days_since_install

    /// Reads the persisted first-launch timestamp from the supplied
    /// `UserDefaults`. On first call (no value), persists `now` and returns
    /// `"0"`. On subsequent calls, returns `floor((now - stored) / 86400)`
    /// stringified.
    ///
    /// Returns `nil` only if the underlying `UserDefaults` access throws — in
    /// practice this shouldn't happen, but the failure path keeps the
    /// auto-collection contract (never crash, never fabricate).
    private static func currentDaysSinceInstall(
        userDefaults: UserDefaults,
        now: Date
    ) -> String? {
        if let storedDate = userDefaults.object(forKey: installDateUserDefaultsKey) as? Date {
            let elapsed = now.timeIntervalSince(storedDate)
            // Negative elapsed time (clock skew, manually-edited install date,
            // or a date-in-the-future seed) clamps to 0 — never a negative
            // count.
            let days = max(0, Int(floor(elapsed / 86_400)))
            return String(days)
        }

        // First launch — seed and return "0". Writes to `UserDefaults` are
        // synchronous and should succeed in normal sandbox conditions, but if
        // they don't we still return "0" rather than throwing; the next launch
        // will re-seed.
        userDefaults.set(now, forKey: installDateUserDefaultsKey)
        return "0"
    }
}
