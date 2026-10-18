import Foundation

public enum Reproduction {
    public static func fixSelection(observation: NotebookObservation, captureId: String, eventId: String, successStatus: Int, reviewedVersion: Int) throws -> NotebookObservation {
        guard observation.editVersion == reviewedVersion, let capture = observation.captures.first(where: { $0.id == captureId }) else { throw LensError.invalid("The observation changed. Review the selected capture again.") }
        _ = try condition(capture: capture, eventId: eventId, successStatus: successStatus)
        var selected = observation
        selected.captures = [capture]
        selected.captures[0].context["includeInAI"] = .bool(true)
        return try EvidenceSanitizer.cloudSelection(selected)
    }
    static func condition(capture: CaptureRecord, eventId: String, successStatus: Int) throws -> JSONValue {
        guard (200...399).contains(successStatus), let row = IncidentEvidence.timeline(capture: capture).first(where: { $0.event.id == eventId }),
              ["response", "devtools-network"].contains(row.event.kind), let status = row.event.data["status"]?.intValue, (400...599).contains(status), row.event.data["status"]?.doubleValue == Double(status) else { throw LensError.invalid("Select a captured HTTP response failure and specify its expected success status (200–399)") }
        let event = row.event
        let request = row.links.filter { $0.relationship == "request" }.compactMap { link in capture.events.first { $0.id == link.target && $0.kind == "request" } }.first
        guard let rawURL = event.data["url"]?.stringValue ?? request?.data["url"]?.stringValue, var url = URLComponents(string: rawURL), ["https", "http"].contains(url.scheme), url.host != nil,
              let method = event.data["method"]?.stringValue ?? request?.data["method"]?.stringValue, ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else { throw LensError.invalid("This failure lacks a recorded request URL/method; inspect its evidence before creating a reproduction") }
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        return .object(["type": .string("http-status"), "url": .string(url.string!), "method": .string(method), "failureStatus": .number(Double(status)), "successStatus": .number(Double(successStatus)), "queryPolicy": .string("Query parameters ignored; origin, path and method must match")])
    }
    public static func handoff(observation: NotebookObservation, eventId: String, successStatus: Int, destination: URL, runner: URL) throws -> URL {
        guard let capture = observation.captures.first(where: { $0.events.contains { $0.id == eventId } }), let event = capture.events.first(where: { $0.id == eventId }) else { throw LensError.invalid("Select the captured HTTP failure") }
        let condition = try Self.condition(capture: capture, eventId: eventId, successStatus: successStatus)
        let actions = capture.events.filter { $0.kind == "action" && $0.timestamp <= event.timestamp && event.timestamp - $0.timestamp <= 10_000 }.suffix(12)
        let contract: JSONValue = .object(["observationId": .string(observation.id), "captureId": .string(capture.id), "failureEventId": .string(eventId), "condition": condition])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let contractData = try encoder.encode(contract)
        let recordedActions = try JSONValue.from(Array(actions))
        let capturedBuild = capture.identity.buildId.map(JSONValue.string) ?? .null
        let handoff: JSONValue = .object(["formatVersion": .number(1), "contract": contract, "contractSHA256": .string(sha256(contractData)), "pageURL": .string(DiagnosticArtifacts.safeURL(capture.identity.url)), "capturedBuildId": capturedBuild, "steps": .array([]), "recordedNearbyActions": recordedActions, "notice": .string("Nearby actions are candidates, not proven reproduction steps. Review the condition and fill steps with goto/click/fill/expectVisible operations before running. Never paste secrets into the shared handoff. Use the same steps and condition for before and after; fix the application in its repository. No commands run during export.")])
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LensError.invalid("Choose a new reproduction folder; existing results are preserved") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try encoder.encode(handoff).write(to: destination.appendingPathComponent("handoff.json"), options: .atomic)
            try FileManager.default.copyItem(at: runner, to: destination.appendingPathComponent("reproduce.mjs"))
            let readme = "Review handoff.json and replace steps with the exact reproduction actions. Supported operations: {op:goto,url}, {op:click,selector}, {op:fill,selector,value}, {op:expectVisible,selector}. Credentials stay in your browser/workspace; never include them in a shared handoff.\n\nRun in a workspace with Playwright installed:\nnode reproduce.mjs before --reviewed\nFix the application, then run the identical script/steps against the fixed build:\nnode reproduce.mjs after --reviewed\n\nSet LENS_REPRO_BUILD to each build commit and LENS_REPRO_BROWSER to a Chromium executable if needed. Each run writes result.json, HAR, trace ZIP and a CPU profile locally. Import result.json through Lens > Diagnostics. Review raw artifacts separately before export or filing. Browser actions may mutate the target application; review the exact steps first. A mismatched or unsuccessful run never proves a fix.\n"
            try Data(readme.utf8).write(to: destination.appendingPathComponent("README.txt"))
            return destination
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    public static func summary(capture: CaptureRecord) -> JSONValue {
        let results = DiagnosticArtifacts.records(capture).compactMap { $0["result"] }.map(DiagnosticArtifacts.summaryResult).filter { $0["captureId"]?.stringValue == capture.id }
        let before = results.last { $0["phase"]?.stringValue == "before" }, after = results.last { $0["phase"]?.stringValue == "after" }
        let same = before != nil && after != nil && ["contractSHA256", "stepsSHA256", "scriptSHA256"].allSatisfy { key in before?[key]?.stringValue?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && before?[key] == after?[key] } && before?["condition"] == after?["condition"] && before?["testOrigin"] == after?["testOrigin"]
        let bound = [before, after].allSatisfy { result in
            guard let result, let success = result["condition"]?["successStatus"]?.intValue,
                  let recorded = try? condition(capture: capture, eventId: result["failureEventId"]?.stringValue ?? "", successStatus: success) else { return false }
            return ["type", "url", "method", "failureStatus", "successStatus"].allSatisfy { recorded[$0] == result["condition"]?[$0] }
        }
        let passed = same && bound && before?["matchingResponseCount"] == .number(1) && after?["matchingResponseCount"] == .number(1) && before?["executionComplete"]?.boolValue == true && after?["executionComplete"]?.boolValue == true && before?["observedStatus"] == before?["condition"]?["failureStatus"] && after?["observedStatus"] == after?["condition"]?["successStatus"] && before?["observedStatus"]?.doubleValue != nil && after?["observedStatus"]?.doubleValue != nil
        let local = before?["testOrigin"]?.stringValue != nil || after?["testOrigin"]?.stringValue != nil
        return .object(["status": .string(passed ? "same-condition-check-passed" : before == nil || after == nil ? "needs-before-and-after" : "incomplete-or-mismatched"), "sameConditionAndSteps": .bool(same), "matchesCapturedFailure": .bool(bound), "localRetest": .bool(local), "before": before ?? .null, "after": after ?? .null, "provenance": .string("Imported runner assertions and checksum-verified artifacts. This proves only the configured HTTP condition for the recorded steps, not the whole application." + (local ? " The captured origin was mapped to a loopback test server. This is a local source check, not a production retest." : " Lens did not independently observe these external runs."))])
    }
}
