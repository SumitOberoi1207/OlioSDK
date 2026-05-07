import SwiftUI

/// A slot that renders a group of CTAs — primary plus optional secondary/tertiary.
///
///     CTAGroupSlot(id: "cta_group", onAction: { action in
///         viewModel.handle(action)
///     }) {
///         VStack {
///             Button("Get started") { }
///             Button("Already have an account? Log in") { }
///         }
///     }
public struct CTAGroupSlot<DefaultContent: View, RenderContent: View>: View {
    let slotID: SlotID
    let defaultBuilder: () -> DefaultContent
    let renderBuilder: ((CTAGroupContent) -> RenderContent)?
    let onAction: ((Action) -> Void)?

    @Environment(\.variantPayload) private var payload

    public init(
        id: SlotID,
        onAction: ((Action) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent
    ) where RenderContent == _DefaultCTAGroupRender {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = nil
        self.onAction = onAction
    }

    public init(
        id: SlotID,
        onAction: ((Action) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent,
        @ViewBuilder render: @escaping (CTAGroupContent) -> RenderContent
    ) {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = render
        self.onAction = onAction
    }

    public var body: some View {
        if let content = payload?.content(for: slotID, as: CTAGroupContent.self) {
            if let renderBuilder = renderBuilder {
                renderBuilder(content)
            } else {
                _DefaultCTAGroupRender(content: content) { action in
                    onAction?(action)
                }
            }
        } else {
            defaultBuilder()
        }
    }
}

public struct _DefaultCTAGroupRender: View {
    let content: CTAGroupContent
    let onAction: (Action) -> Void

    public var body: some View {
        switch content.layout {
        case .stacked:
            VStack(spacing: 12) {
                buttons
            }
        case .horizontal:
            HStack(spacing: 12) {
                buttons
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        ctaButton(content.primary)
        if let secondary = content.secondary {
            ctaButton(secondary)
        }
        if let tertiary = content.tertiary {
            ctaButton(tertiary)
        }
    }

    @ViewBuilder
    private func ctaButton(_ cta: CTAContent) -> some View {
        _DefaultCTARender(content: cta, onAction: onAction)
    }
}
