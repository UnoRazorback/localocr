import SwiftUI

struct StudioDropZoneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isTargeted: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.16 : 0.08))
                    .frame(width: 118, height: 136)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
                    .frame(width: 82, height: 104)
                    .overlay(alignment: .topTrailing) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 0))
                            path.addLine(to: CGPoint(x: 18, y: 0))
                            path.addLine(to: CGPoint(x: 18, y: 18))
                            path.closeSubpath()
                        }
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 18, height: 18)
                        .padding(12)
                    }
                    .overlay {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
            }
            .scaleEffect(isTargeted ? 1.035 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isTargeted)

            VStack(spacing: 8) {
                Text("Drop a document here")
                    .font(.system(.title, design: .rounded, weight: .semibold))

                Text("PDF or image")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Button("Open Document", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityIdentifier("studio.open")

            Label("Processed locally on this Mac.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [8, 6])
                        )
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document drop zone")
        .accessibilityHint("Drop one PDF or image here, or choose Open Document.")
        .accessibilityIdentifier("studio.drop-zone")
    }
}
