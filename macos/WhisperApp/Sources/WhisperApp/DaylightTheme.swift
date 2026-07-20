import SwiftUI
import AppKit

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

enum DaylightPalette {
    static let surface = Color(
        light: NSColor(calibratedRed: 0.957, green: 0.961, blue: 0.969, alpha: 1),
        dark: NSColor(calibratedRed: 0.110, green: 0.118, blue: 0.129, alpha: 1)
    )
    static let border = Color(
        light: NSColor(calibratedRed: 0.929, green: 0.925, blue: 0.902, alpha: 1),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    static let accentActive = Color(
        light: NSColor(calibratedRed: 0.247, green: 0.420, blue: 0.310, alpha: 1),
        dark: NSColor(calibratedRed: 0.361, green: 0.561, blue: 0.431, alpha: 1)
    )
    static let accentRecord = Color(
        light: NSColor(calibratedRed: 0.851, green: 0.314, blue: 0.247, alpha: 1),
        dark: NSColor(calibratedRed: 0.886, green: 0.439, blue: 0.373, alpha: 1)
    )
}

enum DaylightMetric {
    static let cardCornerRadius: CGFloat = 12
    static let sectionSpacing: CGFloat = 18
}

extension MeetingSummaryStatus {
    var daylightColor: Color {
        switch self {
        case .completed: DaylightPalette.accentActive
        case .failed: DaylightPalette.accentRecord
        case .generating, .empty: .secondary
        }
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DaylightMetric.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DaylightMetric.cardCornerRadius)
                    .stroke(DaylightPalette.border, lineWidth: 0.5)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

/// Dot + label capsule used for worker/AI-provider status.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Rounded-pill segmented control that wraps a plain `Binding<T>`, replacing
/// the default `.pickerStyle(.segmented)` look without changing selection logic.
///
/// Provides an `.accessibilityRepresentation` backed by a real `Picker(.segmented)`
/// so VoiceOver and keyboard users get native single-stop/arrow-key segmented
/// navigation even though the visual layer is custom.
struct PillSegmentedControl<T: Hashable & Identifiable, Content: View>: View {
    let options: [T]
    @Binding var selection: T
    var isDisabled: Bool = false
    var accessibilityLabel: String = ""
    @ViewBuilder var label: (T) -> Content

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    label(option)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .foregroundStyle(isSelected ? DaylightPalette.accentActive : .secondary)
                        .background(
                            isSelected ? DaylightPalette.accentActive.opacity(0.14) : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(isSelected ? DaylightPalette.accentActive.opacity(0.4) : DaylightPalette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            Picker(accessibilityLabel, selection: $selection) {
                ForEach(options) { option in
                    label(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isDisabled)
        }
    }
}
