import SwiftUI

/// A slot that renders a single primary call-to-action button.
///
///     CTASlot(id: "primary_cta", onAction: { action in
///         viewModel.handle(action)
///     }) {
///         Button("Continue") { /* default native action */ }
///     }
public struct CTASlot<DefaultContent: View, RenderContent: View>: View {
    let slotID: SlotID
    let defaultBuilder: () -> DefaultContent
    let renderBuilder: ((CTAContent) -> RenderContent)?
    let onAction: ((Action) -> Void)?

    @Environment(\.variantPayload) private var payload

    public init(
        id: SlotID,
        onAction: ((Action) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent
    ) where RenderContent == _DefaultCTARender {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = nil
        self.onAction = onAction
    }

    public init(
        id: SlotID,
        onAction: ((Action) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent,
        @ViewBuilder render: @escaping (CTAContent) -> RenderContent
    ) {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = render
        self.onAction = onAction
    }

    public var body: some View {
        if let content = payload?.content(for: slotID, as: CTAContent.self) {
            if let renderBuilder = renderBuilder {
                renderBuilder(content)
            } else {
                _DefaultCTARender(content: content) { action in
                    onAction?(action)
                }
            }
        } else {
            defaultBuilder()
        }
    }
}

public struct _DefaultCTARender: View {
    let content: CTAContent
    let onAction: (Action) -> Void

    public var body: some View {
        switch content.style {
        case .primary, .destructive:
            Button(action: { onAction(content.action) }) {
                Text(content.label)
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(content.style == .destructive ? .red : .accentColor)
            .disabled(!content.enabled)

        case .secondary:
            Button(action: { onAction(content.action) }) {
                Text(content.label)
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .disabled(!content.enabled)

        case .tertiary:
            Button(action: { onAction(content.action) }) {
                Text(content.label)
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .disabled(!content.enabled)
        }
    }
}
