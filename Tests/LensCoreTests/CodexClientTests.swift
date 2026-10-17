import XCTest
@testable import LensCore

final class CodexClientTests: XCTestCase {
    func testSubscriptionRequestUsesReviewedDataWithoutUserToolsOrAPIKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        var item = NotebookObservation(projectId: "p", markdown: "My report")
        let image = try store.saveArtifact(observationId: item.id, filename: "reviewed.png", data: Data([137,80,78,71,13,10,26,10]))
        item.captures = [CaptureRecord(identity: .init(projectId: "p"), screenshotPath: image.path)]
        let cli = root.appendingPathComponent("codex-fixture")
        let script = """
        #!/usr/bin/python3
        import json,os,sys
        from pathlib import Path
        args=sys.argv[1:]
        if 'status' in args:
          print('Logged in using ChatGPT',file=sys.stderr);sys.exit(0)
        assert '--ignore-user-config' in args and '--ignore-rules' in args and '--ephemeral' in args
        assert 'features.shell_tool=false' in args and 'features.code_mode_host=false' in args
        assert 'features.apps=false' in args and 'features.plugins=false' in args and 'features.hooks=false' in args
        assert 'OPENAI_API_KEY' not in os.environ and 'CODEX_API_KEY' not in os.environ
        instructions_arg=next(arg for arg in args if arg.startswith('model_instructions_file='))
        instructions=Path(json.loads(instructions_arg.split('=',1)[1]))
        assert instructions.is_file() and instructions.parent==Path.cwd()
        assert 'My report' not in instructions.read_text(), 'Untrusted reporter text must not become the trusted instruction file'
        prompt=sys.stdin.read()
        assert 'My report' in prompt and 'originalScreenshotPath' not in prompt
        assert 'reviewed.png' not in prompt
        image=Path(args[args.index('--image')+1]);assert image.is_file() and image.parent==Path.cwd()
        result={'markdown':'Suggested report','findings':[{'kind':'hypothesis','text':'An evidenced possibility','source':None}]}
        print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':json.dumps(result)}}))
        print(json.dumps({'type':'turn.completed'}))
        """
        try Data(script.utf8).write(to: cli);try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let client = CodexClient(executable: cli)
        XCTAssertEqual(client.status(), "ready")
        let result = try client.investigate(observation: item, findings: [], store: store)
        XCTAssertEqual(result.markdown, "Suggested report")
        XCTAssertEqual(result.findings.first?.kind, "hypothesis")
        XCTAssertEqual(item.markdown, "My report")
    }

    func testFailedCodexTurnNeverReturnsAnEmptySuccessfulDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("codex-fixture")
        try Data("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"message\":\"Subscription usage limit reached\"}}'\nexit 1\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        XCTAssertThrowsError(try CodexClient(executable: cli).investigate(observation: .init(projectId: "p"), findings: [], store: .init(root: root))) { error in
            XCTAssertTrue(error.localizedDescription.contains("usage limit"))
        }
    }
}
