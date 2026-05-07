import XCTest
@testable import OlioSDK

final class OlioSDKTests: XCTestCase {

    // MARK: - SlotID / ScreenID

    func testSlotIDStringLiteralCoercion() {
        let id: SlotID = "heading"
        XCTAssertEqual(id.raw, "heading")
        XCTAssertEqual(id.description, "heading")
    }

    func testScreenIDStringLiteralCoercion() {
        let id: ScreenID = "welcome"
        XCTAssertEqual(id.raw, "welcome")
    }

    func testSlotIDCodable() throws {
        let id = SlotID("hero")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(SlotID.self, from: data)
        XCTAssertEqual(id, decoded)
    }

    // MARK: - Action

    func testActionDecodesNext() throws {
        let json = #"{"type":"next"}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(Action.self, from: json)
        XCTAssertEqual(action, .next)
    }

    func testActionDecodesNavigate() throws {
        let json = #"{"type":"navigate","screen":"permissions"}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(Action.self, from: json)
        XCTAssertEqual(action, .navigate(screen: "permissions"))
    }

    func testActionDecodesPurchase() throws {
        let json = #"{"type":"purchase","productId":"saas_annual"}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(Action.self, from: json)
        XCTAssertEqual(action, .purchase(productId: "saas_annual"))
    }

    func testActionUnknownTypeDegradesToTrack() throws {
        let json = #"{"type":"futureActionType"}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(Action.self, from: json)
        if case .track(let event, _) = action {
            XCTAssertEqual(event, "olio.unknown_action")
        } else {
            XCTFail("Expected unknown type to degrade to a track event")
        }
    }

    // MARK: - Content schemas

    func testHeadingContentDecodesMinimal() throws {
        let json = #"""
        {
          "headline": "Find your moment of calm"
        }
        """#.data(using: .utf8)!
        let content = try JSONDecoder().decode(HeadingContent.self, from: json)
        XCTAssertEqual(content.headline, "Find your moment of calm")
        XCTAssertNil(content.eyebrow)
        XCTAssertNil(content.subhead)
        XCTAssertEqual(content.alignment, .leading)
        XCTAssertEqual(content.emphasisStyle, .default)
    }

    func testHeadingContentDecodesFull() throws {
        let json = #"""
        {
          "eyebrow": "Stress relief in 60 seconds",
          "headline": "Breathe through anything.",
          "subhead": "Quick guided sessions.",
          "alignment": "center",
          "emphasisStyle": "display"
        }
        """#.data(using: .utf8)!
        let content = try JSONDecoder().decode(HeadingContent.self, from: json)
        XCTAssertEqual(content.eyebrow, "Stress relief in 60 seconds")
        XCTAssertEqual(content.headline, "Breathe through anything.")
        XCTAssertEqual(content.subhead, "Quick guided sessions.")
        XCTAssertEqual(content.alignment, .center)
        XCTAssertEqual(content.emphasisStyle, .display)
    }

    func testChoiceListContentWithBadge() throws {
        let json = #"""
        {
          "selectionMode": "single",
          "layout": "list",
          "options": [
            {
              "id": "lose",
              "value": "lose_weight",
              "label": "Lose weight",
              "trailingBadge": { "text": "Recommended", "style": "promo" }
            },
            {
              "id": "maintain",
              "value": "maintain_weight",
              "label": "Maintain"
            }
          ]
        }
        """#.data(using: .utf8)!
        let content = try JSONDecoder().decode(ChoiceListContent.self, from: json)
        XCTAssertEqual(content.options.count, 2)
        XCTAssertEqual(content.options[0].trailingBadge?.text, "Recommended")
        XCTAssertEqual(content.options[0].trailingBadge?.style, .promo)
        XCTAssertNil(content.options[1].trailingBadge)
    }

    // MARK: - VariantPayload

    func testVariantPayloadDecodesMultipleSlots() throws {
        let json = #"""
        {
          "screenId": "welcome",
          "variantId": "fb_stress_v1",
          "schemaVersion": "1.0",
          "slots": {
            "heading": {
              "type": "HeadingContent",
              "eyebrow": "Stress relief",
              "headline": "Breathe through anything."
            },
            "hero": {
              "type": "MediaContent",
              "source": {
                "type": "themedIllustration",
                "assetId": "stress_breath",
                "alt": "Breathing visual"
              }
            },
            "primary_cta": {
              "type": "CTAContent",
              "label": "Try a 60-second session",
              "style": "primary",
              "action": { "type": "next" }
            }
          }
        }
        """#.data(using: .utf8)!

        let payload = try JSONDecoder().decode(VariantPayload.self, from: json)
        XCTAssertEqual(payload.screenId, "welcome")
        XCTAssertEqual(payload.variantId, "fb_stress_v1")

        let heading: HeadingContent? = payload.content(for: "heading")
        XCTAssertEqual(heading?.headline, "Breathe through anything.")

        let media: MediaContent? = payload.content(for: "hero")
        if case .themedIllustration(let assetId, _) = media?.source {
            XCTAssertEqual(assetId, "stress_breath")
        } else {
            XCTFail("Expected themedIllustration")
        }

        let cta: CTAContent? = payload.content(for: "primary_cta")
        XCTAssertEqual(cta?.label, "Try a 60-second session")
        XCTAssertEqual(cta?.action, .next)
    }

    func testVariantPayloadIgnoresUnknownSlotType() throws {
        let json = #"""
        {
          "screenId": "welcome",
          "variantId": "v1",
          "slots": {
            "future_slot": {
              "type": "FutureSlotContentType",
              "fancyField": "value"
            },
            "heading": {
              "type": "HeadingContent",
              "headline": "Hello"
            }
          }
        }
        """#.data(using: .utf8)!

        let payload = try JSONDecoder().decode(VariantPayload.self, from: json)
        // Unknown slot type silently dropped — known slot still present
        let heading: HeadingContent? = payload.content(for: "heading")
        XCTAssertNotNil(heading)
        XCTAssertEqual(heading?.headline, "Hello")
    }

    // MARK: - PricingContent

    func testPricingContentDecodesMinimal() throws {
        let json = #"""
        {
          "plans": [
            {
              "id": "monthly",
              "productId": "calm_monthly_999",
              "name": "Monthly",
              "primaryPrice": "$9.99/month"
            }
          ]
        }
        """#.data(using: .utf8)!
        let content = try JSONDecoder().decode(PricingContent.self, from: json)
        XCTAssertEqual(content.plans.count, 1)
        XCTAssertEqual(content.plans[0].id, "monthly")
        XCTAssertFalse(content.plans[0].isHighlighted)
        XCTAssertNil(content.defaultSelectedId)
        XCTAssertFalse(content.showFreeTrialToggle)
    }

    func testPricingContentDecodesFullVariant() throws {
        let json = #"""
        {
          "defaultSelectedId": "annual",
          "plans": [
            {
              "id": "annual",
              "productId": "calm_annual_4999",
              "name": "Annual",
              "primaryPrice": "$49.99/year",
              "secondaryPrice": "$4.16/month",
              "strikethroughPrice": "$119.88",
              "isHighlighted": true,
              "badge": { "text": "Save 58%", "style": "promo" }
            },
            {
              "id": "monthly",
              "productId": "calm_monthly_999",
              "name": "Monthly",
              "primaryPrice": "$9.99/month"
            }
          ]
        }
        """#.data(using: .utf8)!
        let content = try JSONDecoder().decode(PricingContent.self, from: json)
        XCTAssertEqual(content.defaultSelectedId, "annual")
        XCTAssertEqual(content.plans.count, 2)

        let annual = content.plans[0]
        XCTAssertEqual(annual.id, "annual")
        XCTAssertEqual(annual.productId, "calm_annual_4999")
        XCTAssertEqual(annual.primaryPrice, "$49.99/year")
        XCTAssertEqual(annual.secondaryPrice, "$4.16/month")
        XCTAssertEqual(annual.strikethroughPrice, "$119.88")
        XCTAssertTrue(annual.isHighlighted)
        XCTAssertEqual(annual.badge?.text, "Save 58%")
        XCTAssertEqual(annual.badge?.style, .promo)

        let monthly = content.plans[1]
        XCTAssertNil(monthly.badge)
        XCTAssertNil(monthly.strikethroughPrice)
        XCTAssertFalse(monthly.isHighlighted)
    }

    func testVariantPayloadDecodesPricingSlot() throws {
        let json = #"""
        {
          "screenId": "paywall",
          "variantId": "fb_stress_v1",
          "slots": {
            "pricing": {
              "type": "PricingContent",
              "defaultSelectedId": "annual",
              "plans": [
                {
                  "id": "annual",
                  "productId": "calm_annual_4999",
                  "name": "Annual",
                  "primaryPrice": "$49.99/year",
                  "isHighlighted": true,
                  "badge": { "text": "Best value", "style": "promo" }
                }
              ]
            }
          }
        }
        """#.data(using: .utf8)!

        let payload = try JSONDecoder().decode(VariantPayload.self, from: json)
        let pricing: PricingContent? = payload.content(for: "pricing")
        XCTAssertEqual(pricing?.plans.count, 1)
        XCTAssertEqual(pricing?.plans[0].badge?.text, "Best value")
    }

    // MARK: - Attribution

    func testAttributionContextDefaults() {
        let ctx = AttributionContext()
        XCTAssertNil(ctx.mediaSource)
        XCTAssertNil(ctx.campaign)
        XCTAssertTrue(ctx.isFirstLaunch)
        XCTAssertTrue(ctx.utmParams.isEmpty)
        XCTAssertTrue(ctx.extras.isEmpty)
    }

    func testAttributionContextRoundTrips() throws {
        let original = AttributionContext(
            mediaSource: "facebook_ads",
            campaign: "stress_relief_q2",
            adSet: "video_a",
            creative: "creative_3",
            isFirstLaunch: true,
            utmParams: ["utm_source": "fb", "utm_medium": "cpc"],
            extras: ["af_status": "Non-organic"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AttributionContext.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testMockAttributionProviderReturnsInitial() async {
        let initial = AttributionContext(mediaSource: "facebook_ads", campaign: "stress_relief_q2")
        let provider = MockAttributionProvider(initial: initial)
        let result = await provider.attribution()
        XCTAssertEqual(result, initial)
    }

    func testMockAttributionProviderUpdates() async {
        let provider = MockAttributionProvider()
        let initial = await provider.attribution()
        XCTAssertNil(initial)

        let updated = AttributionContext(mediaSource: "tiktok", campaign: "creator_q2")
        await provider.setAttribution(updated)
        let afterSet = await provider.attribution()
        XCTAssertEqual(afterSet, updated)

        await provider.setAttribution(nil)
        let afterClear = await provider.attribution()
        XCTAssertNil(afterClear)
    }

    func testAttributionMappingDefaultRoutesStress() {
        let attribution = AttributionContext(
            mediaSource: "facebook_ads",
            campaign: "stress_relief_q2"
        )
        XCTAssertEqual(AttributionMapping.defaultMapper(attribution), "fb_stress")
    }

    func testAttributionMappingDefaultRoutesSleep() {
        let attribution = AttributionContext(
            mediaSource: "facebook_ads",
            campaign: "Sleep Better Q2"
        )
        XCTAssertEqual(AttributionMapping.defaultMapper(attribution), "fb_sleep")
    }

    func testAttributionMappingDefaultReturnsNilForOrganic() {
        let attribution = AttributionContext(mediaSource: "organic")
        XCTAssertNil(AttributionMapping.defaultMapper(attribution))
    }

    func testAttributionMappingDefaultReturnsNilForUnknownCampaign() {
        let attribution = AttributionContext(
            mediaSource: "facebook_ads",
            campaign: "general_brand_q2"
        )
        XCTAssertNil(AttributionMapping.defaultMapper(attribution))
    }

    func testVariantPayloadTypeMismatchReturnsNil() throws {
        let json = #"""
        {
          "screenId": "welcome",
          "variantId": "v1",
          "slots": {
            "heading": {
              "type": "HeadingContent",
              "headline": "Hello"
            }
          }
        }
        """#.data(using: .utf8)!

        let payload = try JSONDecoder().decode(VariantPayload.self, from: json)
        // Asking for the wrong type returns nil
        let cta: CTAContent? = payload.content(for: "heading")
        XCTAssertNil(cta)
    }
}
