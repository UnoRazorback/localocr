import SwiftUI

extension Color {
    static let localOCRStudioGround = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.071, green: 0.071, blue: 0.063, alpha: 1)
                : NSColor(calibratedRed: 0.957, green: 0.949, blue: 0.925, alpha: 1)
        }
    )
    static let localOCRStudioSurface = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.114, green: 0.114, blue: 0.098, alpha: 1)
                : .white
        }
    )
    static let localOCRStudioOlive = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.682, green: 0.753, blue: 0.447, alpha: 1)
                : NSColor(calibratedRed: 0.290, green: 0.341, blue: 0.161, alpha: 1)
        }
    )
}

enum LocalOCRStudioAppearance: Sendable {
    case light
    case dark
}

struct LocalOCRStudioPalette: Sendable, Equatable {
    let groundHex: String
    let surfaceHex: String
    let inkHex: String
    let accentHex: String
    let tintHex: String
    let alertHex: String

    init(appearance: LocalOCRStudioAppearance) {
        switch appearance {
        case .light:
            groundHex = "F4F2EC"
            surfaceHex = "FFFFFF"
            inkHex = "17160F"
            accentHex = "4A5729"
            tintHex = "E9EBDC"
            alertHex = "8C3A1E"
        case .dark:
            groundHex = "121210"
            surfaceHex = "1D1D19"
            inkHex = "F2F0E9"
            accentHex = "AEC072"
            tintHex = "26261F"
            alertHex = "D98467"
        }
    }
}

struct StudioCornerMarkContract: Sendable, Equatable {
    let pointSize: CGFloat

    var showsFold: Bool { true }
    var showsScanRules: Bool { pointSize >= 60 }
}

struct StudioOnDeviceBadgeContract: Sendable, Equatable {
    let title = "On device"
    let accessibilityLabel = "On device, documents stay on this Mac"
    let isInteractive = false
}

struct StudioCornerMark: View {
    let pointSize: CGFloat

    var body: some View {
        let contract = StudioCornerMarkContract(pointSize: pointSize)
        Canvas { context, size in
            let scale = min(size.width / 52, size.height / 60)
            var page = Path()
            page.move(to: CGPoint(x: 2 * scale, y: 2 * scale))
            page.addLine(to: CGPoint(x: 34 * scale, y: 2 * scale))
            page.addLine(to: CGPoint(x: 50 * scale, y: 18 * scale))
            page.addLine(to: CGPoint(x: 50 * scale, y: 58 * scale))
            page.addLine(to: CGPoint(x: 2 * scale, y: 58 * scale))
            page.closeSubpath()
            context.fill(page, with: .color(.localOCRStudioOlive))

            if contract.showsFold {
                var fold = Path()
                fold.move(to: CGPoint(x: 34 * scale, y: 2 * scale))
                fold.addLine(to: CGPoint(x: 34 * scale, y: 18 * scale))
                fold.addLine(to: CGPoint(x: 50 * scale, y: 18 * scale))
                context.stroke(fold, with: .color(.primary.opacity(0.45)), lineWidth: max(1, 1.5 * scale))
            }

            if contract.showsScanRules {
                for (index, width) in [30.0, 30.0, 18.0].enumerated() {
                    var rule = Path()
                    let y = (31.5 + Double(index) * 8) * scale
                    rule.move(to: CGPoint(x: 11 * scale, y: y))
                    rule.addLine(to: CGPoint(x: (11 + width) * scale, y: y))
                    context.stroke(rule, with: .color(.white.opacity(0.85 - Double(index) * 0.2)), lineWidth: max(1, 2.5 * scale))
                }
            }
        }
        .frame(width: pointSize * 0.87, height: pointSize)
        .accessibilityHidden(true)
    }
}

struct StudioOnDeviceBadge: View {
    private let contract = StudioOnDeviceBadgeContract()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.localOCRStudioOlive)
                .frame(width: 6, height: 6)
            Text(contract.title)
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.localOCRStudioOlive.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(contract.accessibilityLabel)
    }
}
