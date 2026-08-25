import SwiftUI

struct StudioDropZoneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isTargeted: Bool
    let onOpen: () -> Void
    let onNewBatch: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.localOCRStudioOlive.opacity(isTargeted ? 0.18 : 0.09))
                    .frame(width: 118, height: 136)

                StudioCornerMark(pointSize: 92)
                    .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
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

            HStack(spacing: 10) {
                Button("Open Document", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityIdentifier("studio.open")

                Button("New Batch…", action: onNewBatch)
                    .controlSize(.large)
                    .accessibilityHint("Review and process multiple documents one at a time.")
                    .accessibilityIdentifier("studio.new-batch")
            }

            StudioOnDeviceBadge()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.localOCRStudioSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            isTargeted ? Color.localOCRStudioOlive : Color(nsColor: .separatorColor),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [8, 6])
                        )
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document drop zone")
        .accessibilityHint(
            "Drop one PDF or image here, choose Open Document, or start a new batch."
        )
        .accessibilityIdentifier("studio.drop-zone")
    }
}
