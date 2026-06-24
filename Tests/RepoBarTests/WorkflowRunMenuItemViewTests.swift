import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

struct WorkflowRunMenuItemViewTests {
    @MainActor
    @Test
    func `status label prefers job status from conclusion`() throws {
        let url = try #require(URL(string: "https://gitlab.example.com/project/-/jobs/101"))
        let summary = RepoWorkflowRunSummary(
            name: "build",
            url: url,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1),
            status: .pending,
            conclusion: "running",
            branch: "main",
            event: "build",
            actorLogin: "alice",
            actorAvatarURL: nil,
            runNumber: nil
        )

        let view = WorkflowRunMenuItemView(summary: summary) {}

        #expect(view.statusLabel == "running")
    }

    @MainActor
    @Test
    func `status label includes job id when run number is present`() throws {
        let url = try #require(URL(string: "https://gitlab.example.com/project/-/jobs/101"))
        let summary = RepoWorkflowRunSummary(
            name: "build",
            url: url,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1),
            status: .pending,
            conclusion: "running",
            branch: "main",
            event: "build",
            actorLogin: "alice",
            actorAvatarURL: nil,
            runNumber: 101
        )

        let view = WorkflowRunMenuItemView(summary: summary) {}

        #expect(view.statusLabel == "#101 running")
    }

    @MainActor
    @Test
    func `status label falls back to mapped status`() throws {
        let url = try #require(URL(string: "https://github.com/owner/repo/actions/runs/7"))
        let summary = RepoWorkflowRunSummary(
            name: "CI",
            url: url,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1),
            status: .passing,
            conclusion: nil,
            branch: "main",
            event: "push",
            actorLogin: "alice",
            actorAvatarURL: nil,
            runNumber: nil
        )

        let view = WorkflowRunMenuItemView(summary: summary) {}

        #expect(view.statusLabel == "passing")
    }
}
