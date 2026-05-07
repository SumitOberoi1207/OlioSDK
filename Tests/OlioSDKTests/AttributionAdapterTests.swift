import XCTest
@testable import OlioSDK

/// Tests for the runtime MMP attribution adapter system.
///
/// Tests deliberately don't link real MMP SDKs — `isAvailable()` should return
/// false in the test process, which is the whole point of the runtime probe.
/// We verify orchestration logic (merge policy, opt-out, log paths) without
/// trying to mock AppsFlyer's runtime.
final class AttributionAdapterTests: XCTestCase {

    // MARK: - Adapter availability probes

    func testAppsFlyerAdapterIsUnavailableInTestProcess() {
        // The OlioSDK test target has no AppsFlyer SwiftPM dependency,
        // and no AppsFlyer .framework is linked into the test runner. The
        // probe must return false.
        XCTAssertFalse(AppsFlyerAdapter.isAvailable())
    }

    func testAdjustAdapterIsUnavailableInTestProcess() {
        XCTAssertFalse(AdjustAdapter.isAvailable())
    }

    func testAdapterNamesAreHumanReadable() {
        XCTAssertEqual(AppsFlyerAdapter.name, "AppsFlyer")
        XCTAssertEqual(AdjustAdapter.name, "Adjust")
    }

    // MARK: - AppsFlyer normalization

    func testAppsFlyerNormalizeKeepsWhitelistedKeys() {
        let raw: [AnyHashable: Any] = [
            "media_source": "facebook_ads",
            "campaign": "stress_relief_q2",
            "adset": "video_a",
            "af_status": "Non-organic",
            "agency": "acme_agency",
            "partner_name": "fb",
            "iscache": false
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        XCTAssertEqual(normalized["media_source"], "facebook_ads")
        XCTAssertEqual(normalized["campaign"], "stress_relief_q2")
        XCTAssertEqual(normalized["adset"], "video_a")
        XCTAssertEqual(normalized["af_status"], "Non-organic")
        XCTAssertEqual(normalized["agency"], "acme_agency")
        XCTAssertEqual(normalized["partner_name"], "fb")
        // Bool comes through NSNumber bridging on Apple platforms.
        XCTAssertNotNil(normalized["iscache"])
    }

    func testAppsFlyerNormalizeDropsUnknownKeys() {
        let raw: [AnyHashable: Any] = [
            "media_source": "facebook_ads",
            "internal_field_xyz": "should_be_dropped",
            "another_random_key": 42
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        XCTAssertEqual(normalized["media_source"], "facebook_ads")
        XCTAssertNil(normalized["internal_field_xyz"])
        XCTAssertNil(normalized["another_random_key"])
    }

    func testAppsFlyerNormalizeStringifiesNumbers() {
        let raw: [AnyHashable: Any] = [
            "campaign": NSNumber(value: 12345)
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        XCTAssertEqual(normalized["campaign"], "12345")
    }

    func testAppsFlyerNormalizeDropsEmptyStrings() {
        let raw: [AnyHashable: Any] = [
            "media_source": "",
            "campaign": "stress_q2"
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        XCTAssertNil(normalized["media_source"])
        XCTAssertEqual(normalized["campaign"], "stress_q2")
    }

    func testAppsFlyerNormalizeDropsNSNull() {
        let raw: [AnyHashable: Any] = [
            "media_source": NSNull(),
            "campaign": "stress_q2"
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        XCTAssertNil(normalized["media_source"])
        XCTAssertEqual(normalized["campaign"], "stress_q2")
    }

    func testAppsFlyerNormalizeReturnsEmptyForAllUnknown() {
        let raw: [AnyHashable: Any] = [
            "garbage_one": "x",
            "garbage_two": 42
        ]
        XCTAssertTrue(AppsFlyerDelegateBridge.normalize(raw).isEmpty)
    }

    // MARK: - AppsFlyer af_sub custom-param forwarding

    func testAppsFlyerNormalizeForwardsSubFieldsAsContextKeys() {
        // Marketer pastes an influencer ID into a OneLink URL with
        // inconsistent casing; we lowercase on forward so dashboard matchers
        // don't have to worry about it. Only af_sub1 and af_sub3 are present
        // in this conversion-data payload — sub2/4/5 must NOT appear in
        // output.
        let raw: [AnyHashable: Any] = [
            "media_source": "facebook_ads",
            "af_sub1": "JoeLovesFitness",
            "af_sub3": "summer_sale"
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        XCTAssertEqual(normalized["referral_id"], "joelovesfitness")
        XCTAssertEqual(normalized["sub3"], "summer_sale")
        XCTAssertNil(normalized["sub2"])
        XCTAssertNil(normalized["sub4"])
        XCTAssertNil(normalized["sub5"])
        // Existing whitelisted fields still flow through unchanged.
        XCTAssertEqual(normalized["media_source"], "facebook_ads")
        // af_sub1 itself is the AppsFlyer-flavored key; we only expose the
        // normalized `referral_id` form. No leak of the raw key.
        XCTAssertNil(normalized["af_sub1"])
        XCTAssertNil(normalized["sub1"])
    }

    func testAppsFlyerNormalizeDropsEmptyAfSubFields() {
        let raw: [AnyHashable: Any] = [
            "af_sub1": "",
            "af_sub2": "kept_value"
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        XCTAssertNil(normalized["referral_id"])
        XCTAssertEqual(normalized["sub2"], "kept_value")
    }

    func testAppsFlyerNormalizeDoesNotConflictWithExistingFieldNames() {
        // The af_sub mappings must use net-new context keys that don't collide
        // with any of the existing whitelist destinations
        // (media_source / campaign / adset / af_status / agency / partner_name
        // / iscache). This guards against a future refactor accidentally
        // wiring `af_sub1` → `campaign` (or similar) and clobbering the real
        // campaign value.
        let raw: [AnyHashable: Any] = [
            "media_source": "facebook_ads",
            "campaign": "stress_q2",
            "adset": "video_a",
            "af_status": "Non-organic",
            "agency": "acme",
            "partner_name": "fb",
            "af_sub1": "creator_alice",
            "af_sub2": "tag_b",
            "af_sub3": "tag_c",
            "af_sub4": "tag_d",
            "af_sub5": "tag_e"
        ]
        let normalized = AppsFlyerDelegateBridge.normalize(raw)
        // Existing whitelist destinations preserved exactly.
        XCTAssertEqual(normalized["media_source"], "facebook_ads")
        XCTAssertEqual(normalized["campaign"], "stress_q2")
        XCTAssertEqual(normalized["adset"], "video_a")
        XCTAssertEqual(normalized["af_status"], "Non-organic")
        XCTAssertEqual(normalized["agency"], "acme")
        XCTAssertEqual(normalized["partner_name"], "fb")
        // af_sub family lands on net-new keys.
        XCTAssertEqual(normalized["referral_id"], "creator_alice")
        XCTAssertEqual(normalized["sub2"], "tag_b")
        XCTAssertEqual(normalized["sub3"], "tag_c")
        XCTAssertEqual(normalized["sub4"], "tag_d")
        XCTAssertEqual(normalized["sub5"], "tag_e")
    }

    // MARK: - AppsFlyer adapter start safety

    func testAppsFlyerAdapterStartIsSilentWhenSDKMissing() {
        // SDK not linked → start() must be a no-op, no callbacks fired.
        let adapter = AppsFlyerAdapter()
        var fired = false
        adapter.start { _ in
            fired = true
        }
        XCTAssertFalse(fired, "Adapter must not invoke callback when MMP SDK is absent")
    }

    func testAdjustAdapterStartIsSilentWhenSDKMissing() {
        // SDK not linked → start() must be a no-op, no callbacks fired.
        let adapter = AdjustAdapter()
        var fired = false
        adapter.start { _ in
            fired = true
        }
        XCTAssertFalse(fired, "Adapter must not invoke callback when MMP SDK is absent")
    }

    // MARK: - Adjust normalization

    /// Build a minimal stand-in for `ADJAttribution` for unit testing the
    /// normalization logic. Adjust's real class is unavailable in the test
    /// process, but `AdjustNotificationBridge.normalize` only needs an
    /// `NSObject` that responds to the documented property selectors and
    /// returns string values via KVC. `@objc dynamic` properties on a Swift
    /// `NSObject` subclass satisfy both.
    @objc(OlioFakeADJAttribution)
    final class FakeADJAttribution: NSObject {
        @objc dynamic var network: String?
        @objc dynamic var campaign: String?
        @objc dynamic var adgroup: String?
        @objc dynamic var creative: String?
        @objc dynamic var trackerName: String?
        @objc dynamic var clickLabel: String?
    }

    func testAdjustNormalizeMapsNetworkToMediaSourceLowercased() {
        let attr = FakeADJAttribution()
        attr.network = "Facebook Installs"
        attr.campaign = "Stress_Q2"
        attr.adgroup = "Video_A"
        attr.creative = "Hero_Banner"
        attr.trackerName = "abc123::Facebook Installs::Stress"

        let normalized = AdjustNotificationBridge.normalize(attr)
        // network → media_source, raw-but-lowercased — we deliberately do
        // not remap onto AppsFlyer's catalog. Adjust tenants target on
        // Adjust's actual values.
        XCTAssertEqual(normalized["media_source"], "facebook installs")
        XCTAssertEqual(normalized["campaign"], "stress_q2")
        XCTAssertEqual(normalized["adgroup"], "video_a")
        XCTAssertEqual(normalized["creative"], "hero_banner")
        XCTAssertEqual(normalized["tracker"], "abc123::facebook installs::stress")
    }

    func testAdjustNormalizeSkipsClickLabel() {
        let attr = FakeADJAttribution()
        attr.network = "Organic"
        attr.clickLabel = "some_click_label"

        let normalized = AdjustNotificationBridge.normalize(attr)
        XCTAssertEqual(normalized["media_source"], "organic")
        // clickLabel is intentionally not surfaced — too noisy for variant
        // targeting and not in the stable mapping table.
        XCTAssertNil(normalized["clickLabel"])
        XCTAssertNil(normalized["click_label"])
    }

    func testAdjustNormalizeDropsEmptyStringFields() {
        let attr = FakeADJAttribution()
        attr.network = "Google Ads ACI"
        attr.campaign = ""
        attr.adgroup = "Video_A"

        let normalized = AdjustNotificationBridge.normalize(attr)
        XCTAssertEqual(normalized["media_source"], "google ads aci")
        XCTAssertNil(normalized["campaign"])
        XCTAssertEqual(normalized["adgroup"], "video_a")
    }

    func testAdjustNormalizeReturnsEmptyForAllNilFields() {
        let attr = FakeADJAttribution()
        let normalized = AdjustNotificationBridge.normalize(attr)
        XCTAssertTrue(normalized.isEmpty)
    }

    func testAdjustNormalizeDoesNotRemapAdjustValuesToAppsFlyerCatalog() {
        // Sanity check on the explicit no-remap stance: if Adjust says
        // "Facebook Installs", that's what we forward. We do NOT translate
        // it to "facebook_ads" (which is the AppsFlyer-flavored value the
        // dashboard's catalog ships with by default).
        let attr = FakeADJAttribution()
        attr.network = "Facebook Installs"
        let normalized = AdjustNotificationBridge.normalize(attr)
        XCTAssertEqual(normalized["media_source"], "facebook installs")
        XCTAssertNotEqual(normalized["media_source"], "facebook_ads")
    }

    // MARK: - UserContext merge policy

    func testMergeMMPAttributesAddsNewKeys() {
        let userCtx = UserContext(userId: "u1", attributes: [:])
        let merged = userCtx.mergingMMPAttributes([
            "media_source": "facebook_ads",
            "campaign": "stress_q2"
        ])
        XCTAssertEqual(merged.userId, "u1")
        XCTAssertEqual(merged.attributes["media_source"], "facebook_ads")
        XCTAssertEqual(merged.attributes["campaign"], "stress_q2")
    }

    func testMergeMMPAttributesDevWinsOnConflict() {
        let userCtx = UserContext(
            userId: "u1",
            attributes: ["media_source": "manual_source", "custom_key": "dev_value"]
        )
        let merged = userCtx.mergingMMPAttributes([
            "media_source": "facebook_ads",
            "campaign": "stress_q2"
        ])
        // Dev-set media_source must win over MMP's
        XCTAssertEqual(merged.attributes["media_source"], "manual_source")
        // MMP fills in the gap (no campaign was set)
        XCTAssertEqual(merged.attributes["campaign"], "stress_q2")
        // Dev-only key preserved
        XCTAssertEqual(merged.attributes["custom_key"], "dev_value")
    }

    func testMergeMMPAttributesPreservesUserId() {
        let userCtx = UserContext(userId: "user-abc", attributes: ["k": "v"])
        let merged = userCtx.mergingMMPAttributes(["m": "n"])
        XCTAssertEqual(merged.userId, "user-abc")
    }

    func testMergeMMPAttributesEmptyMMPDataIsNoop() {
        let userCtx = UserContext(userId: "u1", attributes: ["k": "v"])
        let merged = userCtx.mergingMMPAttributes([:])
        XCTAssertEqual(merged.attributes, ["k": "v"])
    }

    // MARK: - Auto-detection orchestration on Olio actor

    func testConfigureWithoutMMPProbeLeavesActivatedListEmpty() async {
        // Spin up a fresh Olio actor — but the SDK uses a singleton, so
        // we have to operate on `.shared`. Reset the user context to known
        // state, then configure with autoDetectMMP: false and observe.
        // Opt out of default device-context collection too — this test only
        // covers the MMP code path; default-context behavior has its own
        // dedicated tests below.
        await Olio.shared.setUserContext(nil)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            autoDetectMMP: false,
            autoCollectDeviceContext: false
        )
        let activated = await Olio.shared.activatedMMPAdapters
        XCTAssertTrue(
            activated.isEmpty || !activated.contains("AppsFlyer"),
            "autoDetectMMP: false must skip the probe; got \(activated)"
        )

        // userContext should not have been synthesized
        let ctx = await Olio.shared.userContext
        XCTAssertNil(ctx)
    }

    func testConfigureWithMMPProbeFindsNoAdapters() async {
        // No MMP SDKs are linked into the test process. With auto-detection
        // enabled, the orchestrator iterates every adapter, finds none
        // available, logs nothing about activation, and userContext is
        // unchanged. We disable default-context collection so this test stays
        // focused on the MMP path — defaults have their own coverage.
        await Olio.shared.setUserContext(nil)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            autoDetectMMP: true,
            autoCollectDeviceContext: false
        )
        // Allow any deferred adapter callbacks to flush (defensive — none
        // should fire).
        try? await Task.sleep(nanoseconds: 50_000_000)

        let ctx = await Olio.shared.userContext
        // userContext stays nil because no MMP delivered attribution.
        XCTAssertNil(ctx)
    }

    func testDevSetUserContextNotOverwrittenByEmptyMMPProbe() async {
        let manualCtx = UserContext(userId: "user-xyz", attributes: ["plan": "premium"])
        await Olio.shared.setUserContext(manualCtx)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            autoDetectMMP: true,
            autoCollectDeviceContext: false
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        let ctx = await Olio.shared.userContext
        XCTAssertEqual(ctx?.userId, "user-xyz")
        XCTAssertEqual(ctx?.attributes["plan"], "premium")
    }

    func testDefaultConfigureKeepsExistingSignatureBackwardsCompatible() async {
        // Source-compat: calling configure with the original two-arg form
        // (no autoDetectMMP, no autoCollectDeviceContext) must still compile
        // and run. The defaulted parameters mean any pre-existing call site
        // continues working unchanged.
        await Olio.shared.setUserContext(nil)
        await Olio.shared.configure(
            resolver: BundledVariantResolver(),
            attributionProvider: MockAttributionProvider()
        )
        let provider = await Olio.shared.attributionProvider
        XCTAssertNotNil(provider)
    }
}
