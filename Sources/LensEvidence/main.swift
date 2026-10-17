import Foundation
import LensCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

let args = Array(CommandLine.arguments.dropFirst())
do {
    let result: JSONValue
    if args.isEmpty || args == ["--help"] {
        print("Usage: lens-evidence REPORT_FOLDER inspect|timeline|requests|event|finding|stack|image|verification [ID]\n       lens-evidence REPORT_FOLDER compare OTHER_REPORT_FOLDER\n       lens-evidence REPORT_FOLDER handoff EVENT_ID SUCCESS_STATUS NEW_FOLDER\n       lens-evidence list EXPORTS_DIRECTORY\nReads explicit portable exports only. Handoff writes files; no notebook, network or shell actions.")
        exit(0)
    }
    guard args.count >= 2 else { throw LensError.invalid("Specify a portable report folder and command; use --help") }
    if args[0] == "list" {
        let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).prefix(500)
        result = .array(folders.compactMap { folder in
            guard let report = try? ReviewedEvidence(folder: folder) else { return nil }
            return .object(["id": .string(report.observation.id), "title": .string(report.observation.title), "folder": .string(folder.path), "captures": .number(Double(report.observation.captures.count))])
        })
    } else {
        let report = try ReviewedEvidence(folder: URL(fileURLWithPath: args[0]))
        if args[1] == "handoff" {
            guard args.count == 5, let status = Int(args[3]) else { throw LensError.invalid("handoff EVENT_ID SUCCESS_STATUS NEW_FOLDER") }
            let path = try Reproduction.handoff(observation: report.observation, eventId: args[2], successStatus: status, destination: URL(fileURLWithPath: args[4]), runner: LensPaths.executableDirectory.appendingPathComponent("reproduce.mjs"))
            result = .object(["handoff": .string(path.path), "notice": .string("Review steps before running. Nothing was executed.")])
        } else if args[1] == "compare" {
            guard args.count == 3 else { throw LensError.invalid("Specify the second reviewed report folder") }
            result = try report.compare(to: ReviewedEvidence(folder: URL(fileURLWithPath: args[2])))
        } else { result = try report.query(args[1], id: args.count > 2 ? args[2] : nil) }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(result) + Data([10]))
} catch {
    let value = JSONValue.object(["error": .string(error.localizedDescription)])
    try? FileHandle.standardError.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
    exit(1)
}
