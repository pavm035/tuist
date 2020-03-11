import Basic
import Foundation
import TuistCore
import TuistCoreTesting
import TuistSupport
import XcodeProj
import XCTest
@testable import TuistGenerator
@testable import TuistSupportTesting

final class WorkspaceGeneratorTests: TuistUnitTestCase {
    var subject: WorkspaceGenerator!
    var cocoapodsInteractor: MockCocoaPodsInteractor!

    override func setUp() {
        super.setUp()
        cocoapodsInteractor = MockCocoaPodsInteractor()
        subject = WorkspaceGenerator(cocoapodsInteractor: cocoapodsInteractor)
    }

    override func tearDown() {
        subject = nil
        cocoapodsInteractor = nil
        super.tearDown()
    }

    // MARK: - Tests

    func test_generate_workspaceStructure() throws {
        // Given
        let temporaryPath = try self.temporaryPath()
        try createFiles([
            "README.md",
            "Documentation/README.md",
            "Website/index.html",
            "Website/about.html",
        ])

        let additionalFiles: [FileElement] = [
            .file(path: temporaryPath.appending(RelativePath("README.md"))),
            .file(path: temporaryPath.appending(RelativePath("Documentation/README.md"))),
            .folderReference(path: temporaryPath.appending(RelativePath("Website"))),
        ]

        let graph = Graph.test(entryPath: temporaryPath)
        let workspace = Workspace.test(additionalFiles: additionalFiles)

        // When
        let workspacePath = try subject.generate(workspace: workspace,
                                                 path: temporaryPath,
                                                 graph: graph)

        // Then
        let xcworkspace = try XCWorkspace(pathString: workspacePath.pathString)
        XCTAssertEqual(xcworkspace.data.children, [
            .group(.init(location: .group("Documentation"), name: "Documentation", children: [
                .file(.init(location: .group("README.md"))),
            ])),
            .file(.init(location: .group("README.md"))),
            .file(.init(location: .group("Website"))),
        ])
    }

    func test_generate_workspaceStructure_noWorkspaceData() throws {
        // Given
        let name = "test"
        let temporaryPath = try self.temporaryPath()
        try FileHandler.shared.createFolder(temporaryPath.appending(component: "\(name).xcworkspace"))

        let graph = Graph.test(entryPath: temporaryPath)
        let workspace = Workspace.test(name: name)

        // When
        XCTAssertNoThrow(
            try subject.generate(workspace: workspace,
                                 path: temporaryPath,
                                 graph: graph)
        )
    }

    func test_generate_doesNotWipeUserData() throws {
        // Given
        let temporaryPath = try self.temporaryPath()
        let paths = try createFiles([
            "Foo.xcworkspace/xcuserdata/a",
            "Foo.xcworkspace/xcuserdata/b/c",
        ])

        let graph = Graph.test(entryPath: temporaryPath)
        let workspace = Workspace.test(name: "Foo")

        // When
        try (0 ..< 2).forEach { _ in
            try subject.generate(workspace: workspace,
                                 path: temporaryPath,
                                 graph: graph)
        }

        // Then
        XCTAssertTrue(paths.allSatisfy { FileHandler.shared.exists($0) })
    }

    func test_generate_workspaceStructureWithProjects() throws {
        // Given
        let temporaryPath = try self.temporaryPath()
        let target = anyTarget()
        let project = Project.test(path: temporaryPath,
                                   name: "Test",
                                   settings: .default,
                                   targets: [target])
        let graph = Graph.create(project: project,
                                 dependencies: [(target, [])])
        let workspace = Workspace.test(projects: [project.path])

        // When
        let workspacePath = try subject.generate(workspace: workspace,
                                                 path: temporaryPath,
                                                 graph: graph)

        // Then
        let xcworkspace = try XCWorkspace(pathString: workspacePath.pathString)
        XCTAssertEqual(xcworkspace.data.children, [
            .file(.init(location: .group("Test.xcodeproj"))),
        ])
    }

    func test_generate_runsPodInstall() throws {
        // Given
        let temporaryPath = try self.temporaryPath()
        let target = anyTarget()
        let project = Project.test(path: temporaryPath,
                                   name: "Test",
                                   settings: .default,
                                   targets: [target])
        let graph = Graph.create(project: project,
                                 dependencies: [(target, [])])
        let workspace = Workspace.test(projects: [project.path])

        // When
        _ = try subject.generate(workspace: workspace,
                                 path: temporaryPath,
                                 graph: graph)

        // Then
        XCTAssertEqual(cocoapodsInteractor.installArgs.count, 1)
    }

    func test_generate_addsPackageDependencyManager() throws {
        // Given
        let temporaryPath = try self.temporaryPath()
        let target = anyTarget(dependencies: [
            .package(product: "Example"),
        ])
        let project = Project.test(path: temporaryPath,
                                   name: "Test",
                                   settings: .default,
                                   targets: [target],
                                   packages: [
                                       .remote(url: "http://some.remote/repo.git", requirement: .exact("branch")),
                                   ])
        let graph = Graph.create(project: project,
                                 dependencies: [(target, [])])

        let workspace = Workspace.test(name: project.name,
                                       projects: [project.path])
        let workspacePath = temporaryPath.appending(component: workspace.name + ".xcworkspace")
        system.succeedCommand(["xcodebuild", "-resolvePackageDependencies", "-workspace", workspacePath.pathString, "-list"])
        try createFiles(["\(workspace.name).xcworkspace/xcshareddata/swiftpm/Package.resolved"])

        // When
        try subject.generate(workspace: workspace,
                             path: temporaryPath,
                             graph: graph)

        // Then
        XCTAssertTrue(FileHandler.shared.exists(temporaryPath.appending(component: ".package.resolved")))

        XCTAssertNoThrow(try subject.generate(workspace: workspace,
                                              path: temporaryPath,
                                              graph: graph))
    }

    func test_generate_linksRootPackageResolved_before_resolving() throws {
        // Given
        let temporaryPath = try self.temporaryPath()
        let target = anyTarget(dependencies: [
            .package(product: "Example"),
        ])
        let project = Project.test(path: temporaryPath,
                                   name: "Test",
                                   settings: .default,
                                   targets: [target],
                                   packages: [
                                       .remote(url: "http://some.remote/repo.git", requirement: .exact("branch")),
                                   ])
        let graph = Graph.create(project: project,
                                 dependencies: [(target, [])])

        let workspace = Workspace.test(name: project.name,
                                       projects: [project.path])
        let rootPackageResolvedPath = temporaryPath.appending(component: ".package.resolved")
        try FileHandler.shared.write("package", path: rootPackageResolvedPath, atomically: false)

        let workspacePath = temporaryPath.appending(component: workspace.name + ".xcworkspace")
        system.succeedCommand(["xcodebuild", "-resolvePackageDependencies", "-workspace", workspacePath.pathString, "-list"])

        // When
        try subject.generate(workspace: workspace,
                             path: temporaryPath,
                             graph: graph)

        // Then
        let workspacePackageResolvedPath = temporaryPath.appending(RelativePath("\(workspace.name).xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        XCTAssertEqual(
            try FileHandler.shared.readTextFile(workspacePackageResolvedPath),
            "package"
        )
        try FileHandler.shared.write("changedPackage", path: rootPackageResolvedPath, atomically: false)
        XCTAssertEqual(
            try FileHandler.shared.readTextFile(workspacePackageResolvedPath),
            "changedPackage"
        )
    }

    func test_generate_doesNotAddPackageDependencyManager() throws {
        // Given
        let temporaryPath = try self.temporaryPath()
        let target = anyTarget()
        let project = Project.test(path: temporaryPath,
                                   name: "Test",
                                   settings: .default,
                                   targets: [target])
        let graph = Graph.create(project: project,
                                 dependencies: [(target, [])])

        let workspace = Workspace.test(projects: [project.path])

        // When
        try subject.generate(workspace: workspace,
                             path: temporaryPath,
                             graph: graph)

        // Then
        XCTAssertFalse(FileHandler.shared.exists(temporaryPath.appending(component: ".package.resolved")))
    }

    // MARK: - Helpers

    func anyTarget(dependencies: [Dependency] = []) -> Target {
        Target.test(infoPlist: nil,
                    entitlements: nil,
                    settings: nil,
                    dependencies: dependencies)
    }
}

extension XCWorkspaceDataElement: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case let .file(file):
            return file.location.path
        case let .group(group):
            return group.debugDescription
        }
    }
}

extension XCWorkspaceDataGroup: CustomDebugStringConvertible {
    public var debugDescription: String {
        children.debugDescription
    }
}