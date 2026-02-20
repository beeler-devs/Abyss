import SwiftUI

/// Card UI for repository selection, displaying grouped repositories.
struct RepositorySelectionCardView: View {
    let card: RepositorySelectionCard
    let onSelect: (RepositorySelectionCard.Repository) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText: String = ""

    private var filteredGroups: [(owner: String, repos: [RepositorySelectionCard.Repository])] {
        guard !searchText.isEmpty else { return card.groupedByOwner }

        let lowercased = searchText.lowercased()
        return card.groupedByOwner.compactMap { group in
            let filtered = group.repos.filter {
                $0.name.lowercased().contains(lowercased) ||
                $0.owner.lowercased().contains(lowercased)
            }
            return filtered.isEmpty ? nil : (owner: group.owner, repos: filtered)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Select a Repository")
                        .font(.headline)
                        .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

                    if let prompt = card.prompt {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    }

                    Text("\(card.repositoryCount) repositories across \(card.ownerCount) organizations")
                        .font(.caption)
                        .foregroundStyle(AppTheme.agentCardTertiaryText(for: colorScheme))
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                        .frame(width: 24, height: 24)
                        .background(AppTheme.agentCardDismissBackground(for: colorScheme))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                TextField("Search repositories...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(AppTheme.agentCardDismissBackground(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Repository list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(filteredGroups, id: \.owner) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            // Organization header
                            HStack(spacing: 6) {
                                Image(systemName: "building.2")
                                    .font(.caption)
                                Text(group.owner)
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))

                            // Repository rows
                            ForEach(group.repos) { repo in
                                Button {
                                    onSelect(repo)
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                            .font(.subheadline)
                                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))

                                        Text(repo.name)
                                            .font(.subheadline)
                                            .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.agentCardTertiaryText(for: colorScheme))
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(AppTheme.agentCardDismissBackground(for: colorScheme))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(AppTheme.agentCardBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(AppTheme.agentCardStroke(for: colorScheme), lineWidth: 1)
        )
    }
}
