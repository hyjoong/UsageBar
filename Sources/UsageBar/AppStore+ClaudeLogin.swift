import Foundation
import UsageBarCore

// MARK: Claude sign-in

extension AppStore {
    /// Starts `claude auth login`. The browser opens; when the CLI exits successfully, usage is checked again.
    func startClaudeLogin() {
        guard claudeLoginRun == nil else { return }
        claudeLogin = .waiting(nil)
        if isDemo { return }
        let runner = ClaudeLogin(), id = UUID()
        let showSignInURL: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor in self?.showClaudeSignInURL(url) }
        }
        let task = Task { [weak self] in
            let outcome = await runner.run(onSignInURL: showSignInURL)
            guard let self, self.claudeLoginRun?.id == id else { return }
            self.claudeLoginRun = nil
            switch outcome {
            case .succeeded:
                self.claudeLogin = .idle
                self.claudeConnectionWatch?.cancel()
                await self.refresh(.claude, force: true)
            case .failed(let message): self.claudeLogin = .failed(message)
            case .cancelled: self.claudeLogin = .idle
            }
        }
        claudeLoginRun = (id, runner, task)
    }

    private func showClaudeSignInURL(_ url: URL) {
        if case .waiting = claudeLogin { claudeLogin = .waiting(url) }
    }

    /// Stops the CLI right away, so the button works again at once and quitting leaves no sign-in behind.
    func cancelClaudeLogin() {
        claudeLoginRun?.runner.cancel()
        claudeLoginRun?.task.cancel()
        claudeLoginRun = nil
        claudeLogin = .idle
    }

    /// After the setup Terminal opens, recheck every 5 seconds for up to 10 minutes until Claude connects.
    func watchClaudeConnection() {
        claudeConnectionWatch?.cancel()
        guard !isDemo else { return }
        claudeConnectionWatch = Task { [weak self] in
            let deadline = Date().addingTimeInterval(ClaudeLogin.timeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, self.enabledProviders.contains(.claude),
                      self.states[.claude]?.requiresConnection == true else { return }
                if self.states[.claude]?.isRefreshing != true { await self.refresh(.claude, force: true) }
            }
        }
    }
}
