import SwiftUI

/// Liquid Glass 切换器：一条浅浅的凹槽，选中项底下垫一颗玻璃药丸（同工作列的 GlassPill），
/// 切换时药丸滑过去。
struct GlassModeSwitch: View {
    @Binding var selection: WebSearchMode
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WebSearchMode.allCases, id: \.self) { mode in
                let selected = selection == mode
                Button {
                    selection = mode
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if selected {
                            GlassPill(kind: .selected)
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .fixedSize()
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("搜尋方式")
    }
}
