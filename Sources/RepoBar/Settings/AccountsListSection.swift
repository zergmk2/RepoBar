import Foundation
import RepoBarCore
import SwiftUI

/// Read-write list of configured accounts with select/remove/refresh controls.
///
/// Renders one row per `session.settings.accounts` entry plus a footer
/// describing how to add more accounts (the existing "Account" section below
/// always adds a new account rather than replacing the active one).
struct AccountsListSection: View {
    @Bindable var session: Session
    let appState: AppState

    var body: some View {
        Section {
            if self.session.settings.accounts.isEmpty {
                Text("No accounts configured yet. Sign in below to add your first account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.session.settings.accounts) { account in
                    self.row(for: account)
                    if account.id != self.session.settings.accounts.last?.id {
                        Divider()
                    }
                }
                self.visibleAccountsToggleSummary
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Sign in below to add additional accounts. The active account is used for CLI commands and the default for menu actions.")
        }
    }

    @ViewBuilder
    private func row(for account: Account) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.id == self.session.settings.activeAccountID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(account.id == self.session.settings.activeAccountID ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.usernameAtHost)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(account.authMethod.label)
                    Text("•")
                    Text(account.host.host ?? "github.com")
                    if account.id == self.session.settings.activeAccountID {
                        Text("•")
                        Text("active")
                            .foregroundStyle(.green)
                    }
                    if self.isAccountVisible(account.id) == false {
                        Text("•")
                        Text("hidden")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Button("Use") {
                Task { await self.appState.switchActiveAccount(to: account.id) }
            }
            .controlSize(.small)
            .disabled(account.id == self.session.settings.activeAccountID)

            Toggle("Visible", isOn: self.visibilityBinding(for: account.id))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Show this account's repositories in the menu")

            Button("Check") {
                Task { await self.checkToken(for: account.id) }
            }
            .controlSize(.small)

            Button(role: .destructive) {
                Task { await self.appState.removeAccount(account.id) }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Remove account")
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var visibleAccountsToggleSummary: some View {
        if self.session.settings.accounts.count > 1 {
            HStack(spacing: 8) {
                Text(self.visibilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show all") { self.setAllVisible() }
                    .controlSize(.small)
                    .disabled(self.session.settings.accountSelection == .all)
            }
            .padding(.top, 6)
        }
    }

    private var visibilitySummary: String {
        switch self.session.settings.accountSelection {
        case .all:
            return "All accounts visible in menu."
        case let .only(ids):
            return "Showing \(ids.count) of \(self.session.settings.accounts.count) accounts in menu."
        }
    }

    private func isAccountVisible(_ accountID: String) -> Bool {
        self.session.settings.accountSelection.isVisible(accountID)
    }

    private func visibilityBinding(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { self.session.settings.accountSelection.isVisible(accountID) },
            set: { newValue in self.setVisibility(accountID: accountID, visible: newValue) }
        )
    }

    private func setVisibility(accountID: String, visible: Bool) {
        let allIDs = Set(self.session.settings.accounts.map(\.id))
        let current: Set<String>
        switch self.session.settings.accountSelection {
        case .all:
            current = allIDs
        case let .only(ids):
            current = ids
        }
        var next = current
        if visible {
            next.insert(accountID)
        } else {
            next.remove(accountID)
        }
        if next == allIDs {
            self.session.settings.accountSelection = .all
        } else {
            self.session.settings.accountSelection = .only(next)
        }
        self.appState.persistSettings()
        self.appState.requestRefresh(cancelInFlight: true)
    }

    private func setAllVisible() {
        self.session.settings.accountSelection = .all
        self.appState.persistSettings()
        self.appState.requestRefresh(cancelInFlight: true)
    }

    private func checkToken(for accountID: String) async {
        guard let client = self.appState.accountManager.client(for: accountID) else { return }

        _ = try? await client.currentUser()
    }
}
