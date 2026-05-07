import SwiftUI

/// A slot that renders a single- or multi-select choice list.
///
/// Default-only usage:
///
///     ChoiceListSlot(id: "goal") {
///         VStack {
///             ChoiceCard(label: "Lose weight")
///             ChoiceCard(label: "Maintain")
///             ChoiceCard(label: "Gain weight")
///         }
///     }
///
/// With selection callback:
///
///     ChoiceListSlot(id: "goal", onSelectionChange: { selection in
///         viewModel.goal = selection.first
///     }) {
///         // default content
///     }
public struct ChoiceListSlot<DefaultContent: View, RenderContent: View>: View {
    let slotID: SlotID
    let defaultBuilder: () -> DefaultContent
    let renderBuilder: ((ChoiceListContent, Binding<Set<String>>) -> RenderContent)?
    let onSelectionChange: ((Set<String>) -> Void)?

    @Environment(\.variantPayload) private var payload
    @State private var selection: Set<String> = []

    public init(
        id: SlotID,
        onSelectionChange: ((Set<String>) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent
    ) where RenderContent == _DefaultChoiceListRender {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = nil
        self.onSelectionChange = onSelectionChange
    }

    public init(
        id: SlotID,
        onSelectionChange: ((Set<String>) -> Void)? = nil,
        @ViewBuilder defaultContent: @escaping () -> DefaultContent,
        @ViewBuilder render: @escaping (ChoiceListContent, Binding<Set<String>>) -> RenderContent
    ) {
        self.slotID = id
        self.defaultBuilder = defaultContent
        self.renderBuilder = render
        self.onSelectionChange = onSelectionChange
    }

    public var body: some View {
        if let content = payload?.content(for: slotID, as: ChoiceListContent.self) {
            if let renderBuilder = renderBuilder {
                renderBuilder(content, selectionBinding)
            } else {
                _DefaultChoiceListRender(content: content, selection: selectionBinding)
            }
        } else {
            defaultBuilder()
        }
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                onSelectionChange?(newValue)
            }
        )
    }
}

public struct _DefaultChoiceListRender: View {
    let content: ChoiceListContent
    @Binding var selection: Set<String>

    public var body: some View {
        VStack(spacing: 12) {
            ForEach(content.options) { option in
                Button {
                    toggle(option)
                } label: {
                    optionRow(option)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ option: ChoiceListContent.ChoiceOption) {
        switch content.selectionMode {
        case .single:
            selection = [option.value]
        case .multiple:
            if selection.contains(option.value) {
                selection.remove(option.value)
            } else if let max = content.maxSelections, selection.count >= max {
                return
            } else {
                selection.insert(option.value)
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: ChoiceListContent.ChoiceOption) -> some View {
        let isSelected = selection.contains(option.value)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(option.label)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                    if let badge = option.trailingBadge {
                        Text(badge.text)
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(badgeBackground(badge.style))
                            .foregroundStyle(badgeForeground(badge.style))
                            .clipShape(Capsule())
                    }
                }
                if let description = option.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: indicatorIcon(isSelected: isSelected))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func indicatorIcon(isSelected: Bool) -> String {
        switch (content.selectionMode, isSelected) {
        case (.single, true):    return "checkmark.circle.fill"
        case (.single, false):   return "circle"
        case (.multiple, true):  return "checkmark.square.fill"
        case (.multiple, false): return "square"
        }
    }

    private func badgeBackground(_ style: ChoiceListContent.BadgeContent.Style) -> Color {
        switch style {
        case .promo:   return Color.accentColor
        case .warning: return Color.orange
        case .neutral: return Color.gray.opacity(0.2)
        }
    }

    private func badgeForeground(_ style: ChoiceListContent.BadgeContent.Style) -> Color {
        switch style {
        case .promo, .warning: return .white
        case .neutral:         return .primary
        }
    }
}
