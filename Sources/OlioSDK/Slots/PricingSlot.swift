import SwiftUI

/// A slot that renders a plan tier selector for paywall screens.
///
///     PricingSlot(id: "pricing", onSelectionChange: { id in
///         viewModel.selectedPlanId = id
///     }) {
///         VStack {
///             defaultPlanCard("Annual", price: "$49.99/year")
///             defaultPlanCard("Monthly", price: "$9.99/month")
///         }
///     }
public struct PricingSlot<DefaultContent: View, RenderContent: View>: View {
    let slotID: SlotID
    let defaultBuilder: () -> DefaultContent
    let renderBuilder: ((PricingContent, Binding<String?>) -> RenderContent)?
    let onSelectionChange: ((String?) -> Void)?

    @Environment(\.variantPayload) private var payload
    @State private var selectedPlanId: String?

    public init(
        id: SlotID,
        onSelectionChange: ((String?) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent
    ) where RenderContent == _DefaultPricingRender {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = nil
        self.onSelectionChange = onSelectionChange
    }

    public init(
        id: SlotID,
        onSelectionChange: ((String?) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent,
        @ViewBuilder render: @escaping (PricingContent, Binding<String?>) -> RenderContent
    ) {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = render
        self.onSelectionChange = onSelectionChange
    }

    public var body: some View {
        if let content = payload?.content(for: slotID, as: PricingContent.self) {
            if let renderBuilder = renderBuilder {
                renderBuilder(content, selectionBinding(for: content))
            } else {
                _DefaultPricingRender(
                    content: content,
                    selectedPlanId: selectionBinding(for: content)
                )
            }
        } else {
            defaultBuilder()
        }
    }

    private func selectionBinding(for content: PricingContent) -> Binding<String?> {
        Binding(
            get: { selectedPlanId ?? content.defaultSelectedId ?? content.plans.first?.id },
            set: { newValue in
                selectedPlanId = newValue
                onSelectionChange?(newValue)
            }
        )
    }
}

public struct _DefaultPricingRender: View {
    let content: PricingContent
    @Binding var selectedPlanId: String?

    public var body: some View {
        VStack(spacing: 12) {
            ForEach(content.plans) { plan in
                planCard(plan)
            }
        }
    }

    @ViewBuilder
    private func planCard(_ plan: PricingContent.Plan) -> some View {
        let isSelected = selectedPlanId == plan.id

        Button {
            withAnimation(.spring(duration: 0.25)) {
                selectedPlanId = plan.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                if let badge = plan.badge {
                    Text(badge.text)
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(badgeBackground(badge.style))
                        .foregroundStyle(badgeForeground(badge.style))
                        .clipShape(Capsule())
                }

                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                        if isSelected {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 14, height: 14)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name)
                            .font(.body.bold())
                            .foregroundStyle(Color.primary)
                        if let secondary = plan.secondaryPrice {
                            Text(secondary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        if let strike = plan.strikethroughPrice {
                            Text(strike)
                                .font(.caption)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                        }
                        Text(plan.primaryPrice)
                            .font(.body.bold())
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(plan.isHighlighted ? Color.accentColor.opacity(0.07) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.18),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.04),
                radius: isSelected ? 8 : 3,
                y: isSelected ? 3 : 1
            )
        }
        .buttonStyle(.plain)
    }

    private func badgeBackground(_ style: PricingContent.Plan.Badge.Style) -> Color {
        switch style {
        case .promo:   return Color.accentColor
        case .warning: return Color.orange
        case .neutral: return Color.gray.opacity(0.2)
        }
    }

    private func badgeForeground(_ style: PricingContent.Plan.Badge.Style) -> Color {
        switch style {
        case .promo, .warning: return .white
        case .neutral:         return .primary
        }
    }
}
