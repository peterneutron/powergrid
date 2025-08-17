//
//  QuickActionButton.swift
//  PowerGrid
//
//
//
import SwiftUI
import AppKit

// MARK: - Haptics (optional)
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - QuickActionButton
struct QuickActionButton: View {
    let imageOff: String
    let imageOn: String?
    let title: String?                 // keep for semantics + default tooltip
    @Binding var isOn: Bool
    var size: CGFloat = 48
    var enableHaptics: Bool = true
    var activeTintColor: Color? = nil

    // NEW:
    var helpText: String? = nil        // custom tooltip text
    var showsCaption: Bool = false     // hide label by default
    var accessibilityLabelText: String? = nil
    var action: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        let currentImage = isOn ? (imageOn ?? imageOff) : imageOff

        VStack(spacing: showsCaption ? 8 : 0) {
            Button {
                isOn.toggle()
                action?()
                if enableHaptics { Haptics.tap() }
            } label: {
                Image(systemName: currentImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .help(helpText ?? title ?? currentImage) // tooltip
            .accessibilityLabel(Text(accessibilityLabelText ?? title ?? currentImage))
            .accessibilityValue(Text(isOn ? "On" : "Off"))
            .buttonStyle(
                CircleToggleStyle(
                    isOn: isOn,
                    hovering: hovering,
                    size: size,
                    tintColor: activeTintColor ?? .accentColor
                )
            )

            if showsCaption, let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size * 1.35)
            }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - CircleToggleStyle
struct CircleToggleStyle: ButtonStyle {
    var isOn: Bool
    var hovering: Bool
    var size: CGFloat
    // We default it to .tint so existing buttons that don't provide
    // a color will continue to work as they did before.
    var tintColor: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .scaleEffect(pressed ? 0.96 : (hovering ? 1.03 : 1.0))
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: pressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: hovering)

            // Use Color for consistent ShapeStyle type:
            .foregroundStyle(isOn ? tintColor : Color.primary.opacity(0.85))

            .background(
                ZStack {
                    // Frosted background
                    Circle().fill(.thinMaterial)

                    // Active fill tint
                    if isOn {
                        Circle()
                            .fill(tintColor.opacity(0.22)) // Use the property
                            .transition(.opacity)
                    }

                    // Subtle inner line
                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                        .blur(radius: 0.5)
                        .opacity(0.7)
                }
            )

            // Accent ring — again, Color to avoid ShapeStyle mixing
            .overlay(
                Circle()
                    .strokeBorder(isOn ? tintColor : .secondary.opacity(0.35), // Use the property
                                  lineWidth: isOn ? 1.6 : 1)
                    .opacity(hovering ? 1 : 0.8)
            )

            // Proper shadow overload (with color) to set y-offset
            .shadow(color: .black.opacity(0.25),
                    radius: hovering ? 6 : 3, x: 0, y: hovering ? 2 : 1)
            .shadow(color: .black.opacity(0.001), radius: pressed ? 0 : 0.001)
            .contentShape(Circle())
    }
}

// MARK: - Demo
// struct QuickActionDemo: View {
//    @State private var wifi = true
//    @State private var bt = false
//    @State private var airdrop = false
//    @State private var focus = false
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 14) {
//            Text("Quick Actions").font(.headline)
//
//            let columns = [GridItem(.fixed(80)), GridItem(.fixed(80)),
//                           GridItem(.fixed(80)), GridItem(.fixed(80))]
//            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
//                QuickActionButton(systemImage: "wifi", title: "Wi-Fi", isOn: $wifi)
//                QuickActionButton(systemImage: "bonjour", title: "AirDrop", isOn: $airdrop)
//                QuickActionButton(systemImage: "dot.radiowaves.left.and.right", title: "Bluetooth", isOn: $bt)
//                QuickActionButton(systemImage: "moon.fill", title: "Focus", isOn: $focus)
//            }
//            .padding(.top, 4)
//        }
//        .padding(16)
//        .frame(minWidth: 360)
//    }
//}
//
//#Preview {
//    QuickActionDemo()
//        .frame(width: 380)
//        .environment(\.colorScheme, .dark)
//}
