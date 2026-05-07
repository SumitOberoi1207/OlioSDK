import SwiftUI

/// A slot that renders heading content (eyebrow + headline + subhead).
///
/// Default-only usage:
///
///     HeadingSlot(id: "heading") {
///         Text("Welcome").font(.largeTitle)
///     }
///
/// With custom rendering when variant content is present:
///
///     HeadingSlot(id: "heading") {
///         Text("Welcome").font(.largeTitle)
///     } render: { content in
///         VStack {
///             if let eyebrow = content.eyebrow { Text(eyebrow) }
///             Text(content.headline).font(.largeTitle)
///         }
///     }
public struct HeadingSlot<DefaultContent: View, RenderContent: View>: View {
    let slotID: SlotID
    let defaultBuilder: () -> DefaultContent
    let renderBuilder: ((HeadingContent) -> RenderContent)?

    @Environment(\.variantPayload) private var payload

    /// Default-only initializer — SDK renders variant content when present.
    public init(
        id: SlotID,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent
    ) where RenderContent == _DefaultHeadingRender {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = nil
    }

    /// Default + custom render — your closure receives variant content directly.
    public init(
        id: SlotID,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent,
        @ViewBuilder render: @escaping (HeadingContent) -> RenderContent
    ) {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = render
    }

    public var body: some View {
        if let content = payload?.content(for: slotID, as: HeadingContent.self) {
            if let renderBuilder = renderBuilder {
                renderBuilder(content)
            } else {
                _DefaultHeadingRender(content: content)
            }
        } else {
            defaultBuilder()
        }
    }
}

/// Default SDK rendering for HeadingContent. Public so it satisfies the
/// generic constraint on `HeadingSlot`'s default-only initializer; not intended
/// for direct use.
public struct _DefaultHeadingRender: View {
    let content: HeadingContent

    public var body: some View {
        VStack(alignment: content.alignment.horizontalAlignment, spacing: 8) {
            if let eyebrow = content.eyebrow {
                Text(eyebrow)
                    .font(.caption.bold())
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            Text(content.headline)
                .font(content.emphasisStyle == .display ? .largeTitle.bold() : .title.bold())
            if let subhead = content.subhead {
                Text(subhead)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: content.alignment.frameAlignment)
    }
}

private extension HeadingContent.Alignment {
    var horizontalAlignment: SwiftUI.HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center:  return .center
        }
    }

    var frameAlignment: SwiftUI.Alignment {
        switch self {
        case .leading: return .leading
        case .center:  return .center
        }
    }
}
