# Olio iOS SDK

Customize your app for every audience without an app update.

Olio is a server-driven UI personalization SDK. Your iOS dev declares which screens are personalizable; marketers author per-audience variants and journeys in a web dashboard; this SDK fetches the right content per user at runtime — no App Store releases required.

Backend, dashboard, and AI authoring tools live at [tryolio.ai](https://tryolio.ai).

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/SumitOberoi1207/OlioSDK.git", from: "1.0.0")
```

Or in Xcode: **File → Add Package Dependencies** → paste the URL.

## Quick start

### 1. Configure once at app launch

```swift
import OlioSDK

@main
struct YourApp: App {
    init() {
        Task {
            let resolver = NetworkVariantResolver(
                configuration: .init(
                    baseURL: URL(string: "https://api.tryolio.ai/<your-tenant>")!
                )
            )
            await Olio.shared.configure(resolver: resolver)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

### 2. Wrap personalizable screens

```swift
struct WelcomeScreen: View {
    var body: some View {
        PersonalizableScreen(id: "welcome") {
            VStack {
                MediaSlot(id: "hero") {
                    Image(systemName: "leaf.fill")  // default
                }
                HeadingSlot(id: "heading") {
                    Text("Find your moment of calm")  // default
                }
                CTAGroupSlot(id: "cta_group") {
                    Button("Get started") { /* ... */ }  // default
                }
            }
        }
    }
}
```

Default closures are what users see when no variant matches, the network is down, or the variant fails to load. Olio is fail-open — your app never crashes from a bad variant.

### 3. Drive navigation with the resolved journey

```swift
@Environment(\.olioJourney) private var journey

private func advance(after current: String) {
    if let next = journey.nextScreen(after: current) {
        path.append(next)
    }
}
```

The journey is authored per-audience in the dashboard. The SDK fetches it at startup; iOS just asks "what's next?"

### 4. Forward attribution from your MMP (optional)

The SDK auto-detects AppsFlyer and Adjust at runtime if linked. Or pass attribution manually:

```swift
let provider = MockAttributionProvider()
provider.setAttribution(AttributionContext(
    mediaSource: "facebook_ads",
    campaign: "winter_sale_2026"
))
await Olio.shared.configure(resolver: resolver, attributionProvider: provider)
```

## Slot vocabulary

- `MediaSlot` — image / illustration
- `HeadingSlot` — headline + subheadline + eyebrow
- `CTASlot` — single CTA with action (next / dismiss / navigate / purchase)
- `CTAGroupSlot` — multiple CTAs
- `ChoiceListSlot` — list of selectable choices with badges
- `PricingSlot` — subscription plans

Each slot has a typed default closure plus an optional `render: { content in ... }` for variant-driven rendering.

## Tests

```bash
swift test
```

150+ unit tests covering attribution mapping, variant resolution, journey traversal, slot rendering, and schema validation.

## License

MIT — see `LICENSE`.
