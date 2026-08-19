import Foundation
import Testing

@testable import AgentBarCore

@Suite("Project derivation")
struct ProjectDerivationTests {
    private let resolver = PathProjectResolver()

    @Test("A project is named after its folder, never its path")
    func projectIsNamedAfterItsFolder() {
        let project = resolver.project(for: URL(filePath: "/Users/dev/code/agentbar"))

        #expect(project.name == "agentbar")
        #expect(project.root.path(percentEncoded: false) == "/Users/dev/code/agentbar")
        #expect(project.worktree == nil)
    }

    @Test(
        "Paths that name the same directory group together",
        arguments: [
            "/Users/dev/code/agentbar/",
            "/Users/dev/code/./agentbar",
            "/Users/dev/code/other/../agentbar",
            "/Users/dev/code/AgentBar",
        ]
    )
    func equivalentPathsShareAnIdentity(variant: String) {
        let canonical = resolver.project(for: URL(filePath: "/Users/dev/code/agentbar"))
        #expect(resolver.project(for: URL(filePath: variant)).id == canonical.id)
    }

    @Test("Different directories stay apart")
    func differentDirectoriesStayApart() {
        let one = resolver.project(for: URL(filePath: "/Users/dev/code/agentbar"))
        let other = resolver.project(for: URL(filePath: "/Users/dev/code/agentbar-web"))

        #expect(one.id != other.id)
    }

    /// Without reading git metadata a subdirectory is simply another path. The
    /// `ProjectResolving` seam exists so a layer that may touch the disk can do
    /// better; the domain must not pretend it already has.
    @Test("A subdirectory is its own project until a smarter resolver says otherwise")
    func subdirectoryIsItsOwnProject() {
        let root = resolver.project(for: URL(filePath: "/Users/dev/code/agentbar"))
        let nested = resolver.project(for: URL(filePath: "/Users/dev/code/agentbar/Sources"))

        #expect(root.id != nested.id)
    }

    @Test("The filesystem root does not produce a nameless project")
    func rootDirectoryHasAName() {
        #expect(resolver.project(for: URL(filePath: "/")).name == "/")
    }
}

@Suite("Grouping sessions by project")
struct ProjectGroupingTests {

    @Test("Sessions in one directory are grouped, not merged")
    func parallelSessionsShareAGroup() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, session: "a"))
        await store.apply(Fixture.event(.waitingInput(question: nil), session: "b"))

        let snapshot = await store.snapshot()
        #expect(snapshot.projects.count == 1)
        #expect(snapshot.projects.first?.sessions.count == 2)
        #expect(snapshot.session("a")?.state == .working)
        #expect(snapshot.session("b")?.state == .waitingInput(question: nil))
    }

    /// Two worktrees are two places to work. Merging them would put two agents
    /// editing different branches under one heading.
    @Test("Two worktrees of one repository are two groups")
    func worktreesAreSeparateGroups() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(
            Fixture.event(.turnStarted, session: "main", cwd: "/Users/dev/code/agentbar"))
        await store.apply(
            Fixture.event(
                .turnStarted, session: "feature", cwd: "/Users/dev/code/agentbar.worktrees/ui"))

        let snapshot = await store.snapshot()
        #expect(snapshot.projects.count == 2)
        #expect(snapshot.projects.map(\.sessions.count) == [1, 1])
    }

    /// A resolver that may read the disk fills in the repository a worktree
    /// belongs to. The store must carry it through untouched.
    @Test("A worktree keeps the repository it belongs to")
    func worktreeCarriesItsRepository() async {
        let repository = WorktreeRef(
            repositoryName: "agentbar", repositoryRoot: URL(filePath: "/Users/dev/code/agentbar"))
        let project = ProjectRef(
            id: ProjectID("/users/dev/code/agentbar.worktrees/ui"),
            name: "ui",
            root: URL(filePath: "/Users/dev/code/agentbar.worktrees/ui"),
            worktree: repository)
        let event = AgentEvent(
            provider: .claudeCode,
            sessionId: SessionID("feature"),
            kind: .turnStarted,
            cwd: project.root,
            project: project,
            timestamp: Fixture.epoch)

        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(event)

        #expect(await store.snapshot().projects.first?.project.worktree == repository)
    }

    @Test("A session that changes directory changes group")
    func sessionFollowsItsWorkingDirectory() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, cwd: "/Users/dev/code/agentbar"))
        await store.apply(
            Fixture.event(.toolStarted, cwd: "/Users/dev/code/other", at: 1, toolUseId: "tool-1"))

        let snapshot = await store.snapshot()
        #expect(snapshot.projects.count == 1)
        #expect(snapshot.projects.first?.project.name == "other")
    }

    @Test("Groups are ordered by name so the panel does not reshuffle itself")
    func groupsAreOrderedByName() async {
        let store = SessionStore(clock: ManualTimeSource())
        for path in ["/Users/dev/zulu", "/Users/dev/Alpha", "/Users/dev/mike"] {
            await store.apply(Fixture.event(.turnStarted, session: path, cwd: path))
        }

        let names = await store.snapshot().projects.map(\.project.name)
        #expect(names == ["Alpha", "mike", "zulu"])
    }
}
