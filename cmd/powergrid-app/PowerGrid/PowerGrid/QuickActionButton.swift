//
//  QuickActionButton.swift
//  PowerGrid
//
//
//
// File: QuickActionButton.swift

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
    let title: String?
    @Binding var isOn: Bool
    var size: CGFloat = 48
    var enableHaptics: Bool = true
    var activeTintColor: Color? = nil

    // NEW:
    var helpText: String? = nil
    var showsCaption: Bool = false
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
            .help(helpText ?? title ?? currentImage)
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
    var tintColor: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .scaleEffect(pressed ? 0.96 : (hovering ? 1.03 : 1.0))
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: pressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: hovering)

            .foregroundStyle(isOn ? tintColor : Color.primary.opacity(0.85))

            .background(
                ZStack {
                    Circle().fill(.thinMaterial)

                    if isOn {
                        Circle()
                            .fill(tintColor.opacity(0.22)) // Use the property
                            .transition(.opacity)
                    }

                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                        .blur(radius: 0.5)
                        .opacity(0.7)
                }
            )

            .overlay(
                Circle()
                    .strokeBorder(isOn ? tintColor : .secondary.opacity(0.35),
                                  lineWidth: isOn ? 1.6 : 1)
                    .opacity(hovering ? 1 : 0.8)
            )

            .shadow(color: .black.opacity(0.25),
                    radius: hovering ? 6 : 3, x: 0, y: hovering ? 2 : 1)
            .shadow(color: .black.opacity(0.001), radius: pressed ? 0 : 0.001)
            .contentShape(Circle())
    }
}
