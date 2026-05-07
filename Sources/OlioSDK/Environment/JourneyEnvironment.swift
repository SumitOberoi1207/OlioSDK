import SwiftUI

private struct OlioJourneyKey: EnvironmentKey {
    static let defaultValue: OlioJourney = .empty
}

extension EnvironmentValues {
    /// The PM-authored journey resolved by `Olio.shared.journey()` and injected
    /// at the navigation root, or `.empty` if no journey has been wired.
    ///
    /// Read this in your navigation code to decide which screen comes next:
    ///
    ///     @Environment(\.olioJourney) private var journey
    ///
    ///     // ...
    ///     if let next = journey.nextScreen(after: "welcome") {
    ///         path.append(next)
    ///     }
    ///
    /// An empty journey signals "no campaign override" — fall back to your
    /// hardcoded screen order in that case.
    public var olioJourney: OlioJourney {
        get { self[OlioJourneyKey.self] }
        set { self[OlioJourneyKey.self] = newValue }
    }
}
