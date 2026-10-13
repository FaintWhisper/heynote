import SwiftUI
import UIKit

enum AppDesign {
    static let surface = color(0xF2F2F7, 0x000000)
    static let raised = color(0xFFFFFF, 0x1C1C1E)
    static let bar = color(0xF9F9FB, 0x121213)
    static let text = color(0x17171A, 0xF4F4F6)
    static let secondary = color(0x6A6A70, 0xA1A1A8)
    static let line = color(0xDEDEE3, 0x38383A)
    static let field = color(0xE4E4E9, 0x252528)
    static let accent = color(0x01707A, 0x3FD3A6)
    static let selection = color(0xCDEEE3, 0x0F3D37)
    static let accentUI = adaptive(0x01707A, 0x3FD3A6)
    static let textUI = adaptive(0x17171A, 0xF4F4F6)
    static let raisedUI = adaptive(0xFFFFFF, 0x1C1C1E)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: adaptive(light, dark))
    }
}

struct ChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .regular))
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(AppDesign.accent)
            .contentShape(Rectangle())
            .opacity(!enabled ? 0.35 : (configuration.isPressed ? 0.5 : 1))
    }
}

struct AppChrome<Content: View>: View {
    var title: String? = nil
    var height: CGFloat = 48
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            if let title {
                Text(title).font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).padding(.horizontal, 130)
                    .frame(maxWidth: .infinity).allowsHitTesting(false)
            }
            HStack(spacing: 0) { content }.padding(.horizontal, 8)
        }
        .frame(height: height)
        .foregroundStyle(AppDesign.text)
        .background(AppDesign.bar)
        .buttonStyle(ChromeButtonStyle())
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    var scrolled = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(AppDesign.secondary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundColor(AppDesign.secondary))
                .font(.system(size: 16)).foregroundStyle(AppDesign.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($focused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                        .foregroundStyle(AppDesign.secondary)
                        .frame(width: 28, height: 38)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 11).padding(.trailing, 8)
        .frame(height: 38)
        .background(AppDesign.field, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppDesign.accent, lineWidth: focused ? 2 : 0))
        .padding(.horizontal, 16).padding(.bottom, 12)
        .background(AppDesign.bar)
        .overlay(alignment: .bottom) {
            if scrolled { Rectangle().fill(AppDesign.line).frame(height: 0.5) }
        }
    }
}

struct DesignSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppDesign.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.bottom, 8)
    }
}

struct DesignSectionFoot: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).lineSpacing(3)
            .foregroundStyle(AppDesign.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 14)
    }
}

struct DesignGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) { content }
            .background(AppDesign.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 14)
    }
}

struct DesignRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? AppDesign.text.opacity(0.05) : Color.clear)
    }
}

struct DesignSeparator: View {
    var leading: CGFloat = 15
    var body: some View {
        Rectangle().fill(AppDesign.line).frame(height: 0.5).padding(.leading, leading)
    }
}

struct DesignScrollOffset: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DesignScroll<Content: View>: View {
    @Binding var scrolled: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 22)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: DesignScrollOffset.self,
                                           value: proxy.frame(in: .named("designScroll")).minY)
                })
        }
        .coordinateSpace(name: "designScroll")
        .onPreferenceChange(DesignScrollOffset.self) { scrolled = $0 < -2 }
        .scrollDismissesKeyboard(.interactively)
        .background(AppDesign.surface)
    }
}
