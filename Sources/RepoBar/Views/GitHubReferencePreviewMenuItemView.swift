import RepoBarCore
import SwiftUI

struct GitHubReferencePreviewMenuItemView: View {
    let match: GitHubReferenceMatch
    let onOpen: () -> Void
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        RecentItemRowView(alignment: .top, onOpen: self.onOpen) {
            self.icon
        } content: {
            VStack(alignment: .leading, spacing: 7) {
                self.header
                Text(self.match.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let bodyPreview = self.match.bodyPreview, bodyPreview.isEmpty == false {
                    Text(bodyPreview)
                        .font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(7)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)
                }

                HStack(spacing: 6) {
                    Text(self.match.repositoryFullName)
                        .font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)

                    if let authorLogin = self.match.authorLogin, authorLogin.isEmpty == false {
                        Text(authorLogin)
                            .font(.caption)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }

                    Text(self.dateLabel)
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 640, maxWidth: 720, minHeight: self.match.bodyPreview == nil ? 74 : 160, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(self.referenceLabel)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)

            if let state = self.match.state {
                Text(state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(self.stateColor)
                    .lineLimit(1)
            }

            Text(self.match.kind.label)
                .font(.caption)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
        }
    }

    private var icon: some View {
        Image(systemName: self.systemImage)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(self.stateColor)
            .frame(width: 22, height: 22)
    }

    private var referenceLabel: String {
        switch self.match.query {
        case let .issueNumber(number), let .repositoryIssueNumber(_, number):
            "#\(number)"
        case let .commitHash(hash), let .repositoryCommitHash(_, hash):
            String(hash.prefix(10))
        }
    }

    private var dateLabel: String {
        let date = self.match.createdAt ?? self.match.updatedAt
        let prefix = self.match.createdAt == nil ? "Updated" : "Created"
        return "\(prefix) \(RelativeFormatter.string(from: date, relativeTo: Date()))"
    }

    private var systemImage: String {
        switch self.match.kind {
        case .issue:
            self.match.state == .closed ? "checkmark.circle" : "exclamationmark.circle"
        case .pullRequest:
            switch self.match.state {
            case .merged:
                "arrow.triangle.merge"
            case .closed:
                "xmark.circle"
            case .open, nil:
                "arrow.triangle.branch.circle"
            }
        case .commit:
            "number.square"
        }
    }

    private var stateColor: Color {
        if self.isHighlighted {
            return MenuHighlightStyle.selectionText
        }

        switch self.match.state {
        case .open:
            return Color(nsColor: .systemGreen)
        case .merged:
            return Color(nsColor: .systemPurple)
        case .closed:
            return self.match.kind == .pullRequest
                ? Color(nsColor: .systemRed)
                : Color(nsColor: .secondaryLabelColor)
        case nil:
            return Color(nsColor: .systemBlue)
        }
    }
}
