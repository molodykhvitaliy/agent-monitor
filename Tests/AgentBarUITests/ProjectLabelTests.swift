import AgentBarCore
import Foundation
import Testing

@testable import AgentBarUI

/// `ProjectRef.name` is the last path component, so two checkouts of one
/// repository render as two identical headers — exactly the case a developer
/// using worktrees hits.
@Suite("Project labels")
struct ProjectLabelTests {

    private func labels(_ paths: [String]) -> (ProjectLabels, [ProjectRef]) {
        let projects = paths.map(UIFixture.project)
        return (ProjectLabels(projects: projects), projects)
    }

    @Test("An unambiguous name is left alone")
    func leavesDistinctNames() {
        let (labels, projects) = labels(["/Users/dev/app", "/Users/dev/infra"])
        #expect(labels.label(for: projects[0]) == "app")
        #expect(labels.suffix(for: projects[0]) == nil)
    }

    @Test("A collision is disambiguated from the parent component")
    func disambiguatesFromParent() {
        let (labels, projects) = labels([
            "/Users/dev/code/app", "/Users/dev/worktrees/feature-x/app",
        ])
        #expect(labels.label(for: projects[0]) == "app · code")
        #expect(labels.label(for: projects[1]) == "app · feature-x")
    }

    /// `~/a/x/app` and `~/b/x/app` both yield `x`, so the rule has to keep
    /// walking up until the suffixes actually differ.
    @Test("The walk continues while the parents still tie")
    func walksFurtherUp() {
        let (labels, projects) = labels(["/Users/a/x/app", "/Users/b/x/app"])
        #expect(labels.label(for: projects[0]) == "app · a/x")
        #expect(labels.label(for: projects[1]) == "app · b/x")
    }

    /// The disambiguator comes from `root`, never from `worktree`: a linked
    /// worktree whose leaf equals the repository's own name would give
    /// `app · app`, which distinguishes nothing.
    @Test("A worktree's repository name is not the disambiguator")
    func ignoresWorktreeName() {
        let plain = UIFixture.project("/Users/dev/code/app")
        let linked = ProjectRef(
            id: ProjectID("/users/dev/worktrees/app"),
            name: "app",
            root: URL(filePath: "/Users/dev/worktrees/app"),
            worktree: WorktreeRef(
                repositoryName: "app", repositoryRoot: URL(filePath: "/Users/dev/code/app")))
        let labels = ProjectLabels(projects: [plain, linked])
        #expect(labels.label(for: linked) == "app · worktrees")
        #expect(labels.label(for: linked) != "app · app")
    }

    @Test("Case differences still count as a collision")
    func collidesCaseInsensitively() {
        let (labels, projects) = labels(["/Users/dev/code/App", "/Users/dev/other/app"])
        #expect(labels.suffix(for: projects[0]) == "code")
        #expect(labels.suffix(for: projects[1]) == "other")
    }

    /// A project rooted at `/` has no component to disambiguate from. It must
    /// not crash and must not gain an empty suffix.
    @Test("A project with nothing above it keeps its bare name")
    func toleratesRootProject() {
        let (labels, projects) = labels(["/"])
        #expect(labels.suffix(for: projects[0]) == nil)
    }

    @Test("Three colliding projects are each distinct")
    func handlesThreeWay() {
        let (labels, projects) = labels([
            "/Users/dev/one/app", "/Users/dev/two/app", "/Users/dev/three/app",
        ])
        #expect(Set(projects.map(labels.label(for:))).count == 3)
    }
}
