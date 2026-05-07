import Foundation

/// A PM-authored ordered onboarding journey resolved from the dashboard.
///
/// A journey describes the sequence of screen IDs an end-user should see
/// (`order`) plus a set of screens the PM has flagged to skip (`skip`).
/// Together they let marketing reorder, drop, or re-add screens without
/// shipping a new app build — Olio resolves the journey at runtime from
/// whichever campaign matches the user's targeting context.
///
/// A journey is purely declarative; navigation logic stays in the host app.
/// The host calls `nextScreen(after:)` to walk the order, skipping flagged
/// screens automatically. `shouldShow(_:)` exists as a separate helper for
/// hosts that gate rendering directly (rare — usually `nextScreen` is enough).
///
/// ## Empty journeys
///
/// `OlioJourney.empty` is returned when no campaign matched, when the
/// matched campaign has no journey configured, or when journey resolution
/// fails (network error, bundled-mode SDK, etc.). An empty journey is the
/// "no-op" sentinel: `nextScreen` always returns `nil`, `shouldShow` always
/// returns `false`. Hosts should fall back to their hardcoded screen order
/// when they detect an empty journey.
public struct OlioJourney: Sendable, Equatable {
    public let campaignId: String?
    public let order: [String]
    public let skip: Set<String>

    public static let empty = OlioJourney(campaignId: nil, order: [], skip: [])

    public init(campaignId: String?, order: [String], skip: Set<String>) {
        self.campaignId = campaignId
        self.order = order
        self.skip = skip
    }

    /// Returns the next screen ID after `currentScreen` in the journey,
    /// skipping any screen flagged `skip`. Pass `nil` to get the first
    /// non-skipped screen. Returns nil at the end (or if `currentScreen`
    /// is unknown).
    public func nextScreen(after currentScreen: String?) -> String? {
        // Find starting index. If currentScreen is nil, start from before
        // the first element. If currentScreen isn't in `order`, treat as
        // unknown and return nil — the caller's nav state is out of sync.
        let startIndex: Int
        if let s = currentScreen {
            guard let i = order.firstIndex(of: s) else { return nil }
            startIndex = i + 1
        } else {
            startIndex = 0
        }
        for i in startIndex..<order.count {
            let id = order[i]
            if !skip.contains(id) { return id }
        }
        return nil
    }

    /// True if this screen is in the journey AND not skipped.
    public func shouldShow(_ screenID: String) -> Bool {
        return order.contains(screenID) && !skip.contains(screenID)
    }
}

/// Wire shape of the `/__journey/resolve` Worker response. Decoded internally
/// before being mapped onto the public `OlioJourney` (notably converting
/// `skip: [String]` → `skip: Set<String>` to match the public surface).
struct JourneyDTO: Decodable {
    let campaignId: String?
    let order: [String]
    let skip: [String]
}

