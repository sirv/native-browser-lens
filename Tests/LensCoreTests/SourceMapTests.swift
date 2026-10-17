import XCTest
@testable import LensCore

final class SourceMapTests: XCTestCase {
    func testIndexedMapUsesSectionOffsetAndRejectsRemoteSections() throws {
        let child: JSONValue = .object(["version": .number(3), "sources": .array([.string("src/Save.ts")]), "mappings": .string("AAAA")])
        let section: JSONValue = .object(["offset": .object(["line": .number(2), "column": .number(4)]), "map": child])
        let map: JSONValue = .object(["version": .number(3), "sections": .array([section])])
        XCTAssertNil(try SourceMapResolver.originalPosition(map: map, line: 2, column: 3))
        XCTAssertEqual(try SourceMapResolver.originalPosition(map: map, line: 2, column: 4)?.line, 0)
        XCTAssertEqual(try SourceMapResolver.originalPosition(map: map, line: 2, column: 4)?.map, child)
        let remote: JSONValue = .object(["version": .number(3), "sections": .array([.object(["offset": .object(["line": .number(0), "column": .number(0)]), "url": .string("https://example.test/map")])])])
        XCTAssertThrowsError(try SourceMapResolver.originalPosition(map: remote, line: 0, column: 0))
    }
    func testVLQSegmentsRespectGeneratedLineColumnAndUnmappedBoundary() throws {
        let map: JSONValue = .object(["version": .number(3), "sources": .array([.string("src/Save.ts")]), "names": .array([]), "mappings": .string("AAAA,KACA,K;AACA")])
        let first = try SourceMapResolver.originalPosition(map: map, line: 0, column: 7)
        XCTAssertEqual(first?.line, 1); XCTAssertEqual(first?.column, 0)
        XCTAssertNil(try SourceMapResolver.originalPosition(map: map, line: 0, column: 10))
        XCTAssertEqual(try SourceMapResolver.originalPosition(map: map, line: 1, column: 0)?.line, 2)
        XCTAssertThrowsError(try SourceMapResolver.originalPosition(map: .object(["version": .number(3), "sources": .array([]), "mappings": .string("!!!!")]), line: 0, column: 0))
    }
    func testBuildMapReadsExactCommitAndRejectsDirtyOrUnknownBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dist/assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("throw Error('failed');\n//# sourceMappingURL=save.js.map\n".utf8).write(to: root.appendingPathComponent("dist/assets/save.js"))
        let map: JSONValue = .object(["version": .number(3), "sources": .array([.string("../../src/Save.ts")]), "names": .array([]), "mappings": .string("AAAA"), "sourcesContent": .array([.string("export const save = () => { throw Error('original failure'); };\n")])])
        try JSONEncoder().encode(map).write(to: root.appendingPathComponent("dist/assets/save.js.map"))
        try Data("original source".utf8).write(to: root.appendingPathComponent("src/Save.ts"))
        _ = try LocalRead.command("/usr/bin/git", ["init", "-q"], directory: root.path)
        _ = try LocalRead.command("/usr/bin/git", ["add", "."], directory: root.path)
        _ = try LocalRead.command("/usr/bin/git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "fixture"], directory: root.path)
        let build = try LocalRead.command("/usr/bin/git", ["rev-parse", "HEAD"], directory: root.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("dirty replacement".utf8).write(to: root.appendingPathComponent("dist/assets/save.js.map"))
        let frame: JSONValue = .object(["url": .string("https://example.test/assets/save.js"), "lineNumber": .number(0), "columnNumber": .number(0)])
        let result = try SourceMapResolver.resolve(frame: frame, project: ProjectProfile(repositoryPath: root.path), observedBuild: build)
        XCTAssertTrue(result.content.contains("original failure")); XCTAssertFalse(result.content.contains("dirty replacement"))
        XCTAssertTrue(result.reference.contains("src/Save.ts:1:1")); XCTAssertTrue(result.matchedBuild)
        XCTAssertThrowsError(try SourceMapResolver.resolve(frame: frame, project: ProjectProfile(repositoryPath: root.path), observedBuild: nil))
        XCTAssertThrowsError(try SourceMapResolver.resolve(frame: frame, project: ProjectProfile(repositoryPath: root.path), observedBuild: String(repeating: "a", count: 40)))
        var unsafe = try XCTUnwrap(map.objectValue)
        unsafe["sources"] = .array([.string("../../src/key.pem")])
        unsafe["sourcesContent"] = .array([.string("PRIVATE_KEY_FIXTURE")])
        try JSONEncoder().encode(JSONValue.object(unsafe)).write(to: root.appendingPathComponent("dist/assets/save.js.map"))
        _ = try LocalRead.command("/usr/bin/git", ["add", "."], directory: root.path)
        _ = try LocalRead.command("/usr/bin/git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "unsafe fixture"], directory: root.path)
        let unsafeBuild = try LocalRead.command("/usr/bin/git", ["rev-parse", "HEAD"], directory: root.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertThrowsError(try SourceMapResolver.resolve(frame: frame, project: ProjectProfile(repositoryPath: root.path), observedBuild: unsafeBuild))
    }
}
