import SwiftUI

public struct HelpCenterView: View {
    private let model: HelpCenterModel
    @State private var searchText = ""
    @State private var selectedTopicID: HelpTopicID

    public init(
        model: HelpCenterModel = HelpCenterModel(),
        initialTopic: HelpTopicID = .gettingStarted
    ) {
        self.model = model
        _selectedTopicID = State(initialValue: initialTopic)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.localOCRStudioGround)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.help-center")
    }

    private var filteredTopics: [HelpTopic] {
        model.filteredTopics(matching: searchText)
    }

    private var selectedTopic: HelpTopic {
        model.topic(id: selectedTopicID) ?? model.topics[0]
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StudioCornerMark(pointSize: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LocalOCR")
                        .font(.title2.bold())
                    Text("Help Center")
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Search Help", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search LocalOCR Help")
                .accessibilityIdentifier("studio.help.search")
                .onChange(of: searchText) { _, _ in
                    guard !filteredTopics.contains(where: { $0.id == selectedTopicID }),
                          let first = filteredTopics.first
                    else {
                        return
                    }
                    selectedTopicID = first.id
                }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(filteredTopics) { topic in
                        topicButton(topic)
                    }
                }
            }

            if filteredTopics.isEmpty {
                Text("No Help topics match that search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("studio.help.no-results")
            }
        }
        .padding(20)
        .background(Color.localOCRStudioSurface.opacity(0.72))
    }

    private func topicButton(_ topic: HelpTopic) -> some View {
        Button {
            selectedTopicID = topic.id
        } label: {
            HStack(spacing: 10) {
                Capsule()
                    .fill(
                        selectedTopicID == topic.id
                            ? Color.localOCRStudioOlive
                            : Color.clear
                    )
                    .frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(topic.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                selectedTopicID == topic.id
                    ? Color.localOCRStudioOlive.opacity(0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(topic.title)
        .accessibilityIdentifier("studio.help.topic.\(topic.id.rawValue)")
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(selectedTopic.title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(selectedTopic.summary)
                    .font(.title3)
                    .foregroundStyle(Color.localOCRStudioOlive)
                Divider()
                Text(selectedTopic.body)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                    .accessibilityIdentifier("studio.help.body.\(selectedTopic.id.rawValue)")
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.localOCRStudioGround)
    }
}
