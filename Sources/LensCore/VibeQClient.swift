import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FilingProgress: Codable, Sendable {
    public var stage: String; public var state: String; public var completed: Int; public var total: Int; public var detail: String
    public init(stage: String, state: String, completed: Int = 0, total: Int = 0, detail: String = "") { self.stage=stage; self.state=state; self.completed=completed; self.total=total; self.detail=detail }
}
private struct FilingArtifact: Codable {
    var id: String; var filename: String; var contentType: String; var sha256: String
}
private struct FilingSubmission: Codable {
    var submissionId: String; var observationId: String; var revision: Int; var projectId: String
    var title: String; var markdown: String; var assigneeId: String?; var reviewed = true; var evidenceManifest: [FilingArtifact]
}
private struct FilingAttempt: Codable {
    var endpoint: String; var submission: FilingSubmission; var snapshotHash: String; var exportPath: String; var snapshot: NotebookObservation
    var formatVersion = 2
    var memberId: String?
}
public struct FilingReview: Sendable {
    public let observation: NotebookObservation; public let assigneeId: String?
}
private final class FilingRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct VibeQClient {
    public let baseURL: URL
    private let token: String; private let session: URLSession
    public init(baseURL: URL, token: String, session: URLSession = .shared) { self.baseURL=baseURL; self.token=token; self.session=session }
    public static func rebaseBackup(store: EvidenceStore, oldRoot: String, newRoot: String? = nil) throws {
        let destination = newRoot ?? store.root.path
        guard oldRoot.hasPrefix("/"), oldRoot != "/", destination.hasPrefix("/"), destination != "/" else { throw LensError.invalid("Invalid notebook backup location") }
        func path(_ value: String, id: String) throws -> String {
            let prefix = oldRoot + "/observations/" + id + "/"
            guard value.hasPrefix(prefix), !value.dropFirst(prefix.count).split(separator: "/").contains("..") else { throw LensError.invalid("Backup media leaves its observation") }
            return destination + value.dropFirst(oldRoot.count)
        }
        func rebase(_ value: NotebookObservation) throws -> NotebookObservation {
            var item = value
            for i in item.captures.indices {
                if let p = item.captures[i].screenshotPath { item.captures[i].screenshotPath = try path(p, id: item.id) }
                if let p = item.captures[i].originalScreenshotPath { item.captures[i].originalScreenshotPath = try path(p, id: item.id) }
                if let p = item.captures[i].context["videoPath"]?.stringValue { item.captures[i].context["videoPath"] = .string(try path(p, id: item.id)) }
                var diagnostics = DiagnosticArtifacts.records(item.captures[i])
                for j in diagnostics.indices {
                    if var fields = diagnostics[j].objectValue, let p = fields["path"]?.stringValue { fields["path"] = .string(try path(p, id: item.id)); diagnostics[j] = .object(fields) }
                }
                if !diagnostics.isEmpty { item.captures[i].context["diagnosticArtifacts"] = .array(diagnostics) }
            }
            return item
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for item in try store.observations() {
            try store.save(rebase(item))
            let directory = store.root.appendingPathComponent("observations/" + item.id)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("submission-r") && file.pathExtension == "json" {
                var attempt = try JSONDecoder().decode(FilingAttempt.self, from: Data(contentsOf: file))
                guard attempt.snapshot.id == item.id, attempt.formatVersion == 2 else { throw LensError.invalid("Backup contains an unsupported filing attempt") }
                attempt.snapshot = try rebase(attempt.snapshot)
                attempt.exportPath = try path(attempt.exportPath, id: item.id)
                attempt.snapshotHash = sha256(try encoder.encode(attempt.snapshot))
                _ = try store.saveArtifact(observationId: item.id, filename: file.lastPathComponent, data: encoder.encode(attempt))
            }
        }
    }
    public static func pendingSubmission(observationId: String, revision: Int, store: EvidenceStore) throws -> FilingReview? {
        let url = try store.artifactURL(observationId: observationId, filename: "submission-r\(revision).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attempt = try JSONDecoder().decode(FilingAttempt.self, from: Data(contentsOf: url))
        return FilingReview(observation: attempt.snapshot, assigneeId: attempt.submission.assigneeId)
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") throws -> URLRequest {
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "")), baseURL.user == nil, baseURL.password == nil, !token.isEmpty else { throw LensError.invalid("Use an HTTPS VibeQ endpoint and a personal API token") }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, url.host == baseURL.host else { throw LensError.invalid("Invalid tracker endpoint") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request, delegate: FilingRedirectPolicy())
        guard let http = response as? HTTPURLResponse else { throw LensError.provider("VibeQ returned an invalid response") }
        return (data, http.statusCode)
    }
    public func members() async throws -> [VibeQMember] {
        let (data, status) = try await send(request("/api/members"))
        guard status == 200 else { throw LensError.provider("Could not read VibeQ members (HTTP \(status))") }
        return try JSONDecoder().decode([VibeQMember].self, from: data)
    }
    private func verifiedMember() async throws -> String {
        guard !token.contains(where: { $0.isWhitespace || $0 == ";" }) else { throw LensError.invalid("The VibeQ token has an invalid format") }
        var identityRequest = try request("/auth/me")
        identityRequest.setValue("session=" + token, forHTTPHeaderField: "Cookie")
        let (data, status) = try await send(identityRequest)
        guard status == 200, let id = try JSONDecoder().decode(JSONValue.self, from: data)["id"]?.stringValue, !id.isEmpty else { throw LensError.provider("Could not verify the VibeQ member (HTTP \(status)). The saved submission has not been sent.") }
        return id
    }
    private func reconcile(_ submission: FilingSubmission) async throws -> FilingReceipt? {
        let (data, status) = try await send(request("/api/capture/v1/submissions/" + submission.submissionId))
        if status == 404 { return nil }
        guard status == 200 else { throw LensError.provider("VibeQ outcome is unknown (HTTP \(status)). Retry reconciliation with this saved submission.") }
        return try validate(data, submission: submission)
    }
    private func validate(_ data: Data, submission: FilingSubmission) throws -> FilingReceipt {
        let receipt = try JSONDecoder().decode(FilingReceipt.self, from: data)
        guard receipt.submissionId.lowercased() == submission.submissionId.lowercased(), receipt.observationId.lowercased() == submission.observationId.lowercased(), receipt.revision == submission.revision else { throw LensError.provider("VibeQ returned a receipt for a different submission") }
        guard Set(receipt.missingAttachments).isSubset(of: Set(submission.evidenceManifest.map(\.id))) else { throw LensError.provider("VibeQ returned an inconsistent attachment receipt") }
        return receipt
    }
    /// Explicit review calls this operation. The immutable attempt is saved before any HTTP traffic.
    public func file(observation: NotebookObservation, project: ProjectProfile, store: EvidenceStore, assigneeId: String?, progress: (@Sendable (FilingProgress) -> Void)? = nil) async throws -> FilingReceipt {
        var stage = "prepare"
        func report(_ name: String, _ state: String, _ detail: String = "", completed: Int = 0, total: Int = 0) { progress?(FilingProgress(stage: name, state: state, completed: completed, total: total, detail: detail)) }
        do {
            report(stage, "active", "Saving reviewed revision")
            guard observation.projectId == project.id, !observation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LensError.invalid("Review the project and report title before filing") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var normalized = try EvidenceSanitizer.exportable(observation); normalized.receipt = nil
            let snapshotHash = sha256(try encoder.encode(normalized))
            let attemptURL = try store.artifactURL(observationId: observation.id, filename: "submission-r\(observation.draftRevision).json")
            var attempt: FilingAttempt
            if FileManager.default.fileExists(atPath: attemptURL.path) {
                attempt = try JSONDecoder().decode(FilingAttempt.self, from: Data(contentsOf: attemptURL))
                guard attempt.formatVersion == 2 else { throw LensError.invalid("This legacy submission has no verified member binding. Recover its original tracker receipt before retrying.") }
                guard attempt.endpoint == baseURL.absoluteString else { throw LensError.invalid("This revision has a saved submission to another tracker. Recover it before changing endpoints.") }
                guard attempt.snapshotHash == snapshotHash, attempt.submission.assigneeId == assigneeId else { throw LensError.invalid("This revision already has a frozen submission. Retry its reviewed snapshot before filing an edited amendment.") }
            } else {
                let exportRoot = try store.artifactURL(observationId: observation.id, filename: "filing-r\(observation.draftRevision)")
                let exported = try store.export(observation: normalized, to: exportRoot)
                let files = try FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: [.isRegularFileKey]).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard files.count <= 64 else { throw LensError.invalid("This revision exceeds VibeQ's 64-attachment limit. Split or reduce the reviewed evidence.") }
                let manifest = try files.map { url -> FilingArtifact in
                    let bytes = try Data(contentsOf: url)
                    guard bytes.count <= 200 * 1024 * 1024 else { throw LensError.invalid("An evidence file exceeds the 200 MiB upload limit") }
                    let type = ["png":"image/png", "mp4":"video/mp4", "json":"application/json", "md":"text/markdown"][url.pathExtension] ?? "application/octet-stream"
                    return FilingArtifact(id: stableUUID(observation.id + ":r\(observation.draftRevision):" + url.lastPathComponent).lowercased(), filename: url.lastPathComponent, contentType: type, sha256: sha256(bytes))
                }
                let markdown = try String(contentsOf: exported.appendingPathComponent("report.md"), encoding: .utf8)
                guard normalized.title.count <= 500, markdown.count <= 100_000 else { throw LensError.invalid("The reviewed title or report exceeds VibeQ's size limit") }
                attempt = FilingAttempt(endpoint: baseURL.absoluteString, submission: FilingSubmission(submissionId: UUID().uuidString.lowercased(), observationId: observation.id.lowercased(), revision: observation.draftRevision, projectId: project.id, title: normalized.title, markdown: markdown, assigneeId: assigneeId, evidenceManifest: manifest), snapshotHash: snapshotHash, exportPath: exported.path, snapshot: normalized)
                _ = try store.saveArtifact(observationId: observation.id, filename: attemptURL.lastPathComponent, data: encoder.encode(attempt))
            }
            report(stage, "completed", "Revision \(attempt.submission.revision) saved")
            stage = "reconcile"; report(stage, "active", "Checking the durable tracker receipt")
            let member = try await verifiedMember()
            if let original = attempt.memberId {
                guard original == member else { throw LensError.invalid("This saved submission belongs to another VibeQ member. Restore that member's credentials to recover its receipt; no retry was sent.") }
            } else {
                attempt.memberId = member
                _ = try store.saveArtifact(observationId: observation.id, filename: attemptURL.lastPathComponent, data: encoder.encode(attempt))
            }
            var receipt = try await reconcile(attempt.submission)
            report(stage, "completed", receipt == nil ? "No earlier submission found" : "Existing task recovered")
            let missing = receipt.map { Set($0.missingAttachments) } ?? Set(attempt.submission.evidenceManifest.map(\.id))
            var staged: [JSONValue] = []
            stage = "attachments"; report(stage, "active", "Uploading reviewed evidence", total: missing.count)
            for artifact in attempt.submission.evidenceManifest where missing.contains(artifact.id) {
                let url = URL(fileURLWithPath: attempt.exportPath).appendingPathComponent(artifact.filename)
                let bytes = try Data(contentsOf: url)
                guard sha256(bytes) == artifact.sha256 else { throw LensError.invalid("Saved evidence changed after review; restore the frozen file before retrying") }
                let boundary = "Lens-" + UUID().uuidString
                var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(artifact.filename)\"\r\nContent-Type: \(artifact.contentType)\r\n\r\n".utf8)
                body.append(bytes); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                let (data, status) = try await send(request("/api/attachments/stage", method: "POST", body: body, contentType: "multipart/form-data; boundary=" + boundary))
                guard (200..<300).contains(status), let key = try JSONDecoder().decode(JSONValue.self, from: data)["stagedKey"]?.stringValue else { throw LensError.provider("Attachment upload failed (HTTP \(status)). The saved submission can be retried.") }
                staged.append(.object(["id": .string(artifact.id), "key": .string(key)]))
                report(stage, "active", artifact.filename, completed: staged.count, total: missing.count)
            }
            report(stage, "completed", "\(missing.count) files ready", completed: missing.count, total: missing.count)
            stage = "submit"; report(stage, "active", "Recording the reviewed defect")
            if receipt == nil || !missing.isEmpty {
                var body = try JSONValue.from(attempt.submission).objectValue!
                body["stagedAttachments"] = .array(staged)
                let (data, status) = try await send(request("/api/capture/v1/submissions", method: "POST", body: encoder.encode(JSONValue.object(body))))
                guard status == 200 || status == 201 else { throw LensError.provider("VibeQ submission returned HTTP \(status). The saved identity is retained; reconcile before retrying.") }
                receipt = try validate(data, submission: attempt.submission)
            }
            report(stage, "completed", "Tracker outcome confirmed")
            stage = "receipt"; report(stage, "active", "Saving the tracker receipt locally")
            guard let receipt else { throw LensError.provider("No durable receipt is available") }
            _ = try store.saveArtifact(observationId: observation.id, filename: "receipt-r\(observation.draftRevision).json", data: encoder.encode(receipt))
            report(stage, receipt.missingAttachments.isEmpty ? "completed" : "failed", receipt.missingAttachments.isEmpty ? "Task and attachments confirmed" : "Task saved · \(receipt.missingAttachments.count) attachments need retry")
            return receipt
        } catch { report(stage, "failed", error.localizedDescription); throw error }
    }
}
