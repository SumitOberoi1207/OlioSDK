import XCTest
@testable import OlioSDK

/// Tests for the auto-collected device-context provider that populates
/// `device_type`, `app_version`, and `days_since_install` into
/// `userContext.attributes` at SDK configure time.
///
/// `UserDefaults` access is exercised against a per-test suite (a UUID-namespaced
/// `UserDefaults(suiteName:)`) so the real `com.olio.installDate` key on the
/// shared `.standard` defaults is never touched. Each test cleans up its own
/// suite at the end via `removePersistentDomain(forName:)`.
final class DefaultContextProviderTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a fresh, empty `UserDefaults` suite the test owns. Suite name
    /// is namespaced with a fresh UUID so parallel test runs don't collide.
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suite = "com.olio.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite \(suite)")
            return (UserDefaults.standard, suite)
        }
        // Ensure suite starts empty even if a previous run left state behind
        // (paranoia — UUID suites should already be unique).
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func teardownIsolatedDefaults(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - device_type / app_version basic shape

    func testCollectIncludesDeviceType() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        let attrs = DefaultContextProvider.collect(userDefaults: defaults)
        // Tests run on macOS; depending on whether UIKit is available
        // (Mac Catalyst-style environment) we either get "mac" via the
        // native AppKit branch or "mac" via Catalyst's `.mac` idiom. Either
        // way the key must be present and lowercased to one of the known
        // values.
        XCTAssertNotNil(attrs["device_type"])
        let allowed: Set<String> = ["mac", "iphone", "ipad", "tv", "vision"]
        if let dt = attrs["device_type"] {
            XCTAssertTrue(
                allowed.contains(dt),
                "device_type=\(dt) is not one of the allowed lowercased values"
            )
        }
    }

    func testCollectAppVersionIsAbsentOrNonEmpty() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        let attrs = DefaultContextProvider.collect(userDefaults: defaults)
        // The test bundle may or may not declare CFBundleShortVersionString.
        // The contract is: if absent, the key is omitted; if present, the
        // value is non-empty (we trim and skip empty strings).
        if let v = attrs["app_version"] {
            XCTAssertFalse(v.isEmpty)
        }
    }

    // MARK: - days_since_install

    func testDaysSinceInstallIsZeroOnFirstCall() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        // No stored timestamp yet → first call seeds and returns "0".
        let attrs = DefaultContextProvider.collect(userDefaults: defaults)
        XCTAssertEqual(attrs["days_since_install"], "0")

        // Side effect: the suite now has a Date stored under the documented
        // key. We don't assert exact value (race with `now`), just presence
        // and the right type so we know the public key constant matches what
        // the implementation actually writes.
        let stored = defaults.object(forKey: DefaultContextProvider.installDateUserDefaultsKey)
        XCTAssertNotNil(stored)
        XCTAssertTrue(stored is Date)
    }

    func testDaysSinceInstallReturnsSevenAfterSeedingSevenDaysAgo() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        // Seed an install date 7 days in the past.
        let now = Date()
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)
        defaults.set(sevenDaysAgo, forKey: DefaultContextProvider.installDateUserDefaultsKey)

        let attrs = DefaultContextProvider.collect(userDefaults: defaults, now: now)
        XCTAssertEqual(attrs["days_since_install"], "7")
    }

    func testDaysSinceInstallFloorsPartialDays() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        // 3 days and 23 hours ago → floor to "3".
        let now = Date()
        let elapsed: TimeInterval = 3 * 86_400 + 23 * 3_600
        defaults.set(
            now.addingTimeInterval(-elapsed),
            forKey: DefaultContextProvider.installDateUserDefaultsKey
        )

        let attrs = DefaultContextProvider.collect(userDefaults: defaults, now: now)
        XCTAssertEqual(attrs["days_since_install"], "3")
    }

    func testDaysSinceInstallClampsNegativeElapsedToZero() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        // Stored date is in the future (clock skew or tampering). Implementation
        // clamps to 0 rather than emitting a negative count.
        let now = Date()
        let futureDate = now.addingTimeInterval(86_400)
        defaults.set(futureDate, forKey: DefaultContextProvider.installDateUserDefaultsKey)

        let attrs = DefaultContextProvider.collect(userDefaults: defaults, now: now)
        XCTAssertEqual(attrs["days_since_install"], "0")
    }

    func testCollectDoesNotPoisonStandardUserDefaults() {
        // Sanity: passing an isolated suite must not write to .standard. Read
        // the standard key before and after; require it to be unchanged. (This
        // protects future refactors from accidentally hard-coding `.standard`
        // in the provider implementation.)
        let standardBefore = UserDefaults.standard.object(
            forKey: DefaultContextProvider.installDateUserDefaultsKey
        )

        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }
        _ = DefaultContextProvider.collect(userDefaults: defaults)

        let standardAfter = UserDefaults.standard.object(
            forKey: DefaultContextProvider.installDateUserDefaultsKey
        )
        // Either both nil or both equal — neither value can be a Date written
        // by this test.
        switch (standardBefore as? Date, standardAfter as? Date) {
        case (nil, nil):
            break // nothing written, perfect.
        case let (a?, b?):
            XCTAssertEqual(a, b, "Test mutated UserDefaults.standard")
        default:
            XCTFail("Test mutated UserDefaults.standard (presence changed)")
        }
    }

    func testCollectDoesNotThrowOrCrashUnderTestBundle() {
        // Smoke test: under XCTest the host bundle is the test runner, which
        // may or may not have CFBundleShortVersionString set. The provider's
        // contract is "never throw, never crash, just omit missing keys".
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        // Pure call — if this throws or traps, the test fails.
        _ = DefaultContextProvider.collect(userDefaults: defaults)
    }

    func testCollectIsPureAcrossRepeatedCalls() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { teardownIsolatedDefaults(defaults, suiteName: suite) }

        // First call seeds. Second call against the same `now` must observe
        // the seeded value and return "0" (same day) rather than re-seeding
        // and reporting some other number.
        let now = Date()
        let first = DefaultContextProvider.collect(userDefaults: defaults, now: now)
        let second = DefaultContextProvider.collect(userDefaults: defaults, now: now)
        XCTAssertEqual(first["days_since_install"], "0")
        XCTAssertEqual(second["days_since_install"], "0")
        // device_type / app_version don't change across calls within the same
        // process, so the dicts should be identical.
        XCTAssertEqual(first, second)
    }

    // MARK: - Olio.configure(...) integration: merge precedence + opt-out

    func testConfigureAutoCollectsDefaultsWhenEnabled() async {
        await Olio.shared.setUserContext(nil)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            autoDetectMMP: false,
            autoCollectDeviceContext: true
        )
        let ctx = await Olio.shared.userContext
        // A userContext was synthesized with the defaults.
        XCTAssertNotNil(ctx)
        XCTAssertNotNil(ctx?.attributes["device_type"])
        // days_since_install always populates (UserDefaults.standard always
        // succeeds in a normal sandbox; first call seeds, returns "0").
        XCTAssertNotNil(ctx?.attributes["days_since_install"])
    }

    func testConfigureSkipsDefaultsWhenOptedOut() async {
        // Reset the singleton, then configure with the opt-out and assert the
        // default keys are absent. Dev-set attributes (none here) are the only
        // thing that should populate userContext.
        await Olio.shared.setUserContext(nil)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            autoDetectMMP: false,
            autoCollectDeviceContext: false
        )
        let ctx = await Olio.shared.userContext
        // No defaults were collected and no MMP fired → userContext stays nil.
        XCTAssertNil(ctx)
    }

    func testDevSetAttributesWinOverDefaults() async {
        // Dev sets device_type="iphone" before configure. Defaults will try
        // to set device_type to whatever the test platform reports (likely
        // "mac"). Dev value must win.
        let dev = UserContext(userId: "u-1", attributes: ["device_type": "iphone"])
        await Olio.shared.setUserContext(dev)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            autoDetectMMP: false,
            autoCollectDeviceContext: true
        )
        let ctx = await Olio.shared.userContext
        XCTAssertEqual(ctx?.attributes["device_type"], "iphone")
        // Other defaults still flow through (they're not in conflict).
        XCTAssertNotNil(ctx?.attributes["days_since_install"])
        // userId preserved through the merge.
        XCTAssertEqual(ctx?.userId, "u-1")
    }

    func testMergePrecedenceDefaultsLessThanMMPLessThanDev() {
        // Pure UserContext-level test of the precedence chain — doesn't go
        // through Olio.shared because we want to exercise the data merge
        // alone (the actor wires defaults → MMP → dev order in configure(),
        // but the same precedence is encoded in the merging helpers).
        let dev = UserContext(
            userId: "u-1",
            attributes: ["device_type": "iphone"]
        )
        // Apply defaults first: dev value wins over default for device_type.
        let withDefaults = dev.mergingDefaultAttributes([
            "device_type": "ipad",          // default loses to dev
            "days_since_install": "0"       // default fills the gap
        ])
        XCTAssertEqual(withDefaults.attributes["device_type"], "iphone")
        XCTAssertEqual(withDefaults.attributes["days_since_install"], "0")

        // Then overlay an MMP that wants to set device_type — dev still wins.
        let withMMP = withDefaults.mergingMMPAttributes([
            "device_type": "ipad",          // MMP also loses to dev
            "media_source": "facebook_ads"  // MMP fills the gap
        ])
        XCTAssertEqual(withMMP.attributes["device_type"], "iphone")
        XCTAssertEqual(withMMP.attributes["days_since_install"], "0")
        XCTAssertEqual(withMMP.attributes["media_source"], "facebook_ads")
    }

    func testMergeDefaultAttributesEmptyMapIsNoop() {
        let userCtx = UserContext(userId: "u1", attributes: ["k": "v"])
        let merged = userCtx.mergingDefaultAttributes([:])
        XCTAssertEqual(merged.attributes, ["k": "v"])
    }

    func testMergeDefaultAttributesIntoEmptyContext() {
        let userCtx = UserContext(userId: nil, attributes: [:])
        let merged = userCtx.mergingDefaultAttributes([
            "device_type": "iphone",
            "app_version": "2.5.0"
        ])
        XCTAssertEqual(merged.attributes["device_type"], "iphone")
        XCTAssertEqual(merged.attributes["app_version"], "2.5.0")
        XCTAssertNil(merged.userId)
    }
}
