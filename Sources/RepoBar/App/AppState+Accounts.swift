import Foundation
import RepoBarCore

extension AppState {
    /// Bootstraps the account manager and runs one-shot legacy migration on first launch.
    ///
    /// Migration steps:
    /// 1. If `settings.accounts` is already populated, just hand them to the manager.
    /// 2. Otherwise probe legacy single-account credentials (OAuth, then PAT) and
    ///    derive a single `Account` from `GET /user`. Move tokens under the new
    ///    account-scoped Keychain keys and persist `settings.accounts`.
    /// 3. Mark the discovered account active so all existing single-account
    ///    code paths keep working through `session.activeAccountID`.
    func bootstrapAccounts() async {
        let manager = self.accountManager
        if self.session.settings.accounts.isEmpty {
            if let migrated = await self.migrateLegacyAccountIfNeeded() {
                self.session.settings.accounts = [migrated]
                self.session.settings.activeAccountID = migrated.id
                self.persistSettings()
            }
        }
        await manager.bootstrap(from: self.session.settings)
        self.session.activeAccountID = manager.activeAccountID
        self.session.accountSessions = self.session.settings.accounts.map { account in
            AccountSession(account: account)
        }
    }

    /// Attempts to discover an existing single-account login and convert it into a
    /// multi-account `Account` record. Returns `nil` when no credentials exist.
    private func migrateLegacyAccountIfNeeded() async -> Account? {
        let tokenStore = TokenStore.shared
        let oauthTokens = try? tokenStore.load()
        let legacyPAT = try? tokenStore.loadPAT()
        let legacyCreds = try? tokenStore.loadClientCredentials()
        guard oauthTokens != nil || legacyPAT != nil else { return nil }

        let host = self.session.settings.enterpriseHost ?? self.session.settings.githubHost
        let preferredMethod: AuthMethod = oauthTokens != nil ? .oauth : .pat

        // Use a one-off probe client to call /user with whichever credentials exist.
        let identity = await self.probeLegacyIdentity(
            host: host,
            oauthTokens: oauthTokens,
            pat: legacyPAT
        )

        // Fall back to a synthesized identity so PAT-only users without network access still migrate.
        let username = identity?.username
            ?? self.fallbackUsernameFromSettings()
            ?? "user"

        let account = Account(
            username: username,
            host: host,
            authMethod: preferredMethod,
            loopbackPort: self.session.settings.loopbackPort,
            clientID: legacyCreds?.clientID
        )

        if let oauthTokens {
            try? tokenStore.save(tokens: oauthTokens, accountID: account.id)
        }
        if let legacyCreds {
            try? tokenStore.save(clientCredentials: legacyCreds, accountID: account.id)
        }
        if let legacyPAT {
            try? tokenStore.savePAT(legacyPAT, accountID: account.id)
        }
        // Clearing the legacy fixed keys ensures the user lands on the new schema
        // and that future single-account read paths fall through to the account-scoped keys.
        tokenStore.clear()
        tokenStore.clearPAT()

        return account
    }

    private func probeLegacyIdentity(
        host: URL,
        oauthTokens: OAuthTokens?,
        pat: String?
    ) async -> UserIdentity? {
        let apiHost = Account.deriveAPIHost(for: host)
        let probe = GitHubClient()
        await probe.setAPIHost(apiHost)
        await probe.setTokenProvider { @Sendable in
            if let oauthTokens {
                return oauthTokens
            }
            if let pat {
                return OAuthTokens(accessToken: pat, refreshToken: "", expiresAt: nil)
            }
            return nil
        }
        return try? await probe.currentUser()
    }

    private func fallbackUsernameFromSettings() -> String? {
        if case let .loggedIn(identity) = self.session.account, identity.username.isEmpty == false {
            return identity.username
        }
        return nil
    }

    /// Records a freshly authenticated identity as an `Account` and registers it
    /// with `AccountManager` so the account list reflects the new login.
    ///
    /// For OAuth logins the legacy fixed Keychain keys are also copied under
    /// the account-scoped keys so the per-account refresher can take over.
    func recordAccountForLogin(
        user: UserIdentity,
        host: URL,
        method: AuthMethod,
        persistPAT pat: String? = nil
    ) async {
        guard user.username.isEmpty == false else { return }

        let account = Account(
            username: user.username,
            host: host,
            authMethod: method,
            loopbackPort: self.session.settings.loopbackPort,
            clientID: (try? TokenStore.shared.loadClientCredentials())?.clientID
        )

        switch method {
        case .oauth:
            if let tokens = try? TokenStore.shared.load() {
                try? TokenStore.shared.save(tokens: tokens, accountID: account.id)
            }
            if let creds = try? TokenStore.shared.loadClientCredentials() {
                try? TokenStore.shared.save(clientCredentials: creds, accountID: account.id)
            }
        case .pat:
            let token = pat ?? (try? TokenStore.shared.loadPAT())
            if let token {
                try? TokenStore.shared.savePAT(token, accountID: account.id)
            }
        }

        await self.accountManager.add(account)
        if let index = self.session.settings.accounts.firstIndex(where: { $0.id == account.id }) {
            self.session.settings.accounts[index] = account
        } else {
            self.session.settings.accounts.append(account)
        }
        if self.session.settings.activeAccountID == nil {
            self.session.settings.activeAccountID = account.id
        }
        self.session.activeAccountID = self.accountManager.activeAccountID
        self.session.accountSessions = self.session.settings.accounts.map { existing in
            if let current = self.session.accountSessions.first(where: { $0.id == existing.id }) {
                return current
            }
            return AccountSession(account: existing)
        }
        self.persistSettings()
    }

    /// Switches the active account by ID. No-op when the ID is unknown.
    func switchActiveAccount(to accountID: String) async {
        guard self.accountManager.setActive(accountID: accountID) else { return }

        self.session.activeAccountID = accountID
        self.session.settings.activeAccountID = accountID
        self.persistSettings()
        // Trigger a refresh so the menu reflects the new active account.
        self.requestRefresh(cancelInFlight: true)
    }

    /// Removes an account, clears its tokens, and updates the active selection.
    func removeAccount(_ accountID: String) async {
        await self.accountManager.remove(accountID: accountID)
        self.session.settings.accounts.removeAll(where: { $0.id == accountID })
        self.session.accountSessions.removeAll(where: { $0.id == accountID })
        if self.session.settings.activeAccountID == accountID {
            self.session.settings.activeAccountID = self.session.settings.accounts.first?.id
            self.session.activeAccountID = self.session.settings.activeAccountID
        }
        // Drop any per-account pinned/hidden lists for the removed account.
        var lists = self.session.settings.accountRepoLists
        lists.pinnedByAccount.removeValue(forKey: accountID)
        lists.hiddenByAccount.removeValue(forKey: accountID)
        self.session.settings.accountRepoLists = lists
        self.persistSettings()
        self.requestRefresh(cancelInFlight: true)
    }
}
