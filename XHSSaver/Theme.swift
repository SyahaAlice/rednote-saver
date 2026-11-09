import SwiftUI

/// 视觉风格：与图标一致的玫红 → 紫渐变，卡片式布局
enum Theme {
    static let rose = Color(red: 1.0, green: 94 / 255, blue: 126 / 255)
    static let violet = Color(red: 106 / 255, green: 61 / 255, blue: 240 / 255)
    static var gradient: LinearGradient {
        LinearGradient(colors: [rose, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 圆角卡片
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

/// 主按钮：渐变胶囊
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.gradient.opacity(isEnabled ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.violet.opacity(isEnabled ? 0.3 : 0), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// 和主按钮并排的第二个按钮：同样大小，浅色底
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Theme.violet : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.violet.opacity(isEnabled ? 0.12 : 0.05),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// 次要按钮：浅色胶囊
struct ChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .background(Color.accentColor.opacity(isEnabled ? 0.12 : 0.05), in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 小标签
struct FeatureTag: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

/// 卡片标题：图标 + 文字
struct CardTitle: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.headline)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.gradient)
        }
    }
}
