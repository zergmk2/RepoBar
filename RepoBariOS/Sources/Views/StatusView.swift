import RepoBarCore
import SwiftUI
import UIKit

struct StatusView: View {
    @Bindable var appModel: AppModel
    @Environment(\.openURL) private var openURL
    @State private var referenceText = ""

    private var rateLimitState: RateLimitDisplayState {
        RateLimitDisplayState(diagnostics: appModel.session.diagnostics)
    }

    var body: some View {
        List {
            referenceResolverSection
            resolvedReferencesSection
            rateLimitSection
        }
        .scrollContentBackground(.hidden)
        .background(GlassBackground())
        .listStyle(.insetGrouped)
        .navigationTitle("Status")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await appModel.refreshRateLimits() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await appModel.refreshRateLimits()
        }
    }

    private var referenceResolverSection: some View {
        Section {
            TextEditor(text: $referenceText)
                .frame(minHeight: 104)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Button {
                    referenceText = UIPasteboard.general.string ?? ""
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }

                Spacer()

                Button {
                    Task { await appModel.resolveReferences(from: referenceText) }
                } label: {
                    if appModel.session.isResolvingReferences {
                        ProgressView()
                    } else {
                        Label("Resolve", systemImage: "magnifyingglass")
                    }
                }
                .disabled(referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("GitHub References")
        } footer: {
            Text("Paste issues, pull requests, commits, GitHub URLs, or grouped owner/repo lists.")
        }
    }

    @ViewBuilder
    private var resolvedReferencesSection: some View {
        if let error = appModel.session.referenceError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }

        if appModel.session.referenceMatches.isEmpty == false {
            Section("Matches") {
                ForEach(appModel.session.referenceMatches, id: \.url) { match in
                    Button {
                        openURL(match.url)
                    } label: {
                        ReferenceMatchRow(match: match)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = match.url.absoluteString
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }

    private var rateLimitSection: some View {
        Section {
            Label(rateLimitState.compactSummary(), systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)

            if let error = appModel.session.rateLimitError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            ForEach(Array(rateLimitState.sections().enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                ForEach(Array(section.resourceRows.enumerated()), id: \.offset) { _, row in
                    RateLimitRow(row: row)
                }
            }
        } header: {
            Text("GitHub Rate Limits")
        } footer: {
            Text("Live resource buckets, endpoint cooldowns, and reset times from the same diagnostics used by the macOS menu.")
        }
    }
}

private struct ReferenceMatchRow: View {
    let match: GitHubReferenceMatch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: match.symbolName)
                .font(.title3)
                .foregroundStyle(match.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(match.query.displayText)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(match.statusLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(match.tint)
                }

                Text(match.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(match.repositoryFullName)
                    Text(match.kind.label)
                    Text(RelativeFormatter.string(from: match.updatedAt, relativeTo: Date()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RateLimitRow: View {
    let row: RateLimitDisplayRow

    var body: some View {
        if row.resource != nil || row.quotaText != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.resource ?? row.text)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    if let quotaText = row.quotaText {
                        Text(quotaText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let percent = row.percentRemaining {
                    ProgressView(value: percent, total: 100)
                        .tint(percent <= 10 ? .red : .green)
                }

                if let resetText = row.resetText {
                    Text(resetText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text(row.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }
}
