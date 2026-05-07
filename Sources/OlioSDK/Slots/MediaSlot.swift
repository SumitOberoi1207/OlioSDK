import SwiftUI

/// A slot that renders hero media — image, animation, video, or themed illustration.
///
/// Default-only usage:
///
///     MediaSlot(id: "hero") {
///         Image("default_landscape").resizable().scaledToFit()
///     }
public struct MediaSlot<DefaultContent: View, RenderContent: View>: View {
    let slotID: SlotID
    let defaultBuilder: () -> DefaultContent
    let renderBuilder: ((MediaContent) -> RenderContent)?

    @Environment(\.variantPayload) private var payload

    public init(
        id: SlotID,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent
    ) where RenderContent == _DefaultMediaRender {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = nil
    }

    public init(
        id: SlotID,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent,
        @ViewBuilder render: @escaping (MediaContent) -> RenderContent
    ) {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = render
    }

    public var body: some View {
        if let content = payload?.content(for: slotID, as: MediaContent.self) {
            if let renderBuilder = renderBuilder {
                renderBuilder(content)
            } else {
                _DefaultMediaRender(content: content)
            }
        } else {
            defaultBuilder()
        }
    }
}

public struct _DefaultMediaRender: View {
    let content: MediaContent

    public var body: some View {
        Group {
            switch content.source {
            case .image(let url, let alt):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Color.gray.opacity(0.1)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    case .failure:
                        Color.gray.opacity(0.1)
                    @unknown default:
                        Color.gray.opacity(0.1)
                    }
                }
                .accessibilityLabel(alt)

            case .themedIllustration(let assetId, let alt):
                // Customer's app bundles the asset by name; the SDK looks it up.
                Image(assetId)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityLabel(alt)

            case .lottie, .video:
                // v1 placeholder — Lottie + video need additional dependencies.
                Color.gray.opacity(0.1)
            }
        }
        .aspectRatio(content.aspectRatio.map { CGFloat($0) }, contentMode: contentMode)
    }

    private var contentMode: ContentMode {
        switch content.fitMode {
        case .fit:           return .fit
        case .fill, .cover:  return .fill
        }
    }
}
