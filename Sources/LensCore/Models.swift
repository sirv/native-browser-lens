import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    public var intValue: Int? { doubleValue.flatMap { $0.isFinite && $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue? { objectValue?[key] }
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public var pretty: String { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? String(data: e.encode(self), encoding: .utf8)) ?? "null" }
}

public func nowMilliseconds() -> Double { Date().timeIntervalSince1970 * 1000 }

public struct OwnerRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { pattern + memberId }
    public var pattern: String; public var memberId: String; public var label: String
    public init(pattern: String = "", memberId: String = "", label: String = "") { self.pattern = pattern; self.memberId = memberId; self.label = label }
}
public struct ProjectProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var name: String; public var origins: [String]; public var repositoryPath: String
    public var documentationPaths: [String]; public var recording: String; public var enabled: Bool; public var adapter: String
    public var ownership: [OwnerRule]; public var logPaths: [String]
    public init(id: String = UUID().uuidString, name: String = "New project", origins: [String] = [], repositoryPath: String = "", documentationPaths: [String] = ["docs"], recording: String = "diagnostics", enabled: Bool = false, adapter: String = "generic", ownership: [OwnerRule] = [], logPaths: [String] = []) {
        self.id=id; self.name=name; self.origins=origins; self.repositoryPath=repositoryPath; self.documentationPaths=documentationPaths; self.recording=recording; self.enabled=enabled; self.adapter=adapter; self.ownership=ownership; self.logPaths=logPaths
    }
}
public struct TabStatus: Codable, Equatable, Identifiable, Sendable {
    public var selected: Bool?
    public var clientId: String?
    public var id: Int { tabId }; public var tabId: Int; public var windowId: Int; public var projectId: String; public var url: String; public var title: String; public var mode: String; public var documentId: String; public var armedAt: Double; public var capabilities: [String]; public var reason: String?; public var active: Bool
    public init(tabId: Int, windowId: Int = 0, projectId: String, url: String, title: String = "", mode: String = "unavailable", documentId: String = "", armedAt: Double = nowMilliseconds(), capabilities: [String] = [], reason: String? = nil, active: Bool = false) { self.tabId=tabId; self.windowId=windowId; self.projectId=projectId; self.url=url; self.title=title; self.mode=mode; self.documentId=documentId; self.armedAt=armedAt; self.capabilities=capabilities; self.reason=reason; self.active=active }
}
public struct CaptureIdentity: Codable, Equatable, Sendable {
    public var clientId: String?
    public var projectId: String; public var tabId: Int; public var windowId: Int; public var documentId: String; public var url: String; public var title: String; public var capturedAt: Double; public var buildId: String?
    public init(projectId: String, tabId: Int = -1, windowId: Int = -1, documentId: String = UUID().uuidString, url: String = "", title: String = "", capturedAt: Double = nowMilliseconds(), buildId: String? = nil) { self.projectId=projectId; self.tabId=tabId; self.windowId=windowId; self.documentId=documentId; self.url=url; self.title=title; self.capturedAt=capturedAt; self.buildId=buildId }
}
public struct EvidenceEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var projectId: String; public var tabId: Int; public var documentId: String; public var timestamp: Double; public var kind: String; public var data: [String: JSONValue]
    public init(id: String = UUID().uuidString, projectId: String, tabId: Int, documentId: String, timestamp: Double = nowMilliseconds(), kind: String, data: [String: JSONValue] = [:]) { self.id=id; self.projectId=projectId; self.tabId=tabId; self.documentId=documentId; self.timestamp=timestamp; self.kind=kind; self.data=data }
}
public struct CoverageGap: Codable, Equatable, Identifiable, Sendable {
    public var id: String { channel + String(startedAt) + reason }; public var channel: String; public var reason: String; public var startedAt: Double; public var endedAt: Double?
    public init(channel: String, reason: String, startedAt: Double = nowMilliseconds(), endedAt: Double? = nil) { self.channel=channel; self.reason=reason; self.startedAt=startedAt; self.endedAt=endedAt }
}
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double
    public init(x: Double, y: Double) { self.x = min(1, max(0, x)); self.y = min(1, max(0, y)) }
}
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var kind: String; public var points: [NormalizedPoint]; public var color: String
    public init(id: String = UUID().uuidString, kind: String = "rectangle", points: [NormalizedPoint] = [], color: String = "#FF643C") { self.id=id; self.kind=kind; self.points=points; self.color=color }
}
public struct CaptureRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var identity: CaptureIdentity; public var events: [EvidenceEvent]; public var gaps: [CoverageGap]; public var context: [String: JSONValue]; public var screenshotPath: String?; public var originalScreenshotPath: String?; public var annotations: [Annotation]
    public init(id: String = UUID().uuidString, identity: CaptureIdentity, events: [EvidenceEvent] = [], gaps: [CoverageGap] = [], context: [String: JSONValue] = [:], screenshotPath: String? = nil, originalScreenshotPath: String? = nil, annotations: [Annotation] = []) { self.id=id; self.identity=identity; self.events=events; self.gaps=gaps; self.context=context; self.screenshotPath=screenshotPath; self.originalScreenshotPath=originalScreenshotPath; self.annotations=annotations }
}
public struct Finding: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var kind: String; public var text: String; public var source: String?; public var confidence: Double?
    public init(id: String = UUID().uuidString, kind: String, text: String, source: String? = nil, confidence: Double? = nil) { self.id=id; self.kind=kind; self.text=text; self.source=source; self.confidence=confidence }
}
public struct FilingReceipt: Codable, Equatable, Sendable {
    public var submissionId: String; public var observationId: String; public var revision: Int; public var taskId: String; public var taskUrl: String; public var createdAt: Double; public var attachmentStatus: String; public var missingAttachments: [String]
    public init(submissionId: String, observationId: String, revision: Int, taskId: String, taskUrl: String, createdAt: Double = nowMilliseconds(), attachmentStatus: String = "complete", missingAttachments: [String] = []) { self.submissionId=submissionId; self.observationId=observationId; self.revision=revision; self.taskId=taskId; self.taskUrl=taskUrl; self.createdAt=createdAt; self.attachmentStatus=attachmentStatus; self.missingAttachments=missingAttachments }
}
public struct NotebookObservation: Codable, Equatable, Identifiable, Sendable {
    public var archivedAt: Double?
    public var trashedAt: Double?
    public var id: String; public var projectId: String; public var createdAt: Double; public var title: String; public var markdown: String; public var draftRevision: Int; public var editVersion: Int; public var captures: [CaptureRecord]; public var findings: [Finding]; public var receipt: FilingReceipt?
    public init(id: String = UUID().uuidString, projectId: String, createdAt: Double = nowMilliseconds(), title: String = "Untitled observation", markdown: String = "", draftRevision: Int = 1, editVersion: Int = 0, captures: [CaptureRecord] = [], findings: [Finding] = [], receipt: FilingReceipt? = nil) { self.id=id; self.projectId=projectId; self.createdAt=createdAt; self.title=title; self.markdown=markdown; self.draftRevision=draftRevision; self.editVersion=editVersion; self.captures=captures; self.findings=findings; self.receipt=receipt }
}
public struct WireMessage: Codable, Equatable, Identifiable, Sendable {
    public var version: Int; public var kind: String; public var id: String; public var payload: JSONValue
    public init(version: Int = 1, kind: String, id: String = UUID().uuidString, payload: JSONValue = .object([:])) { self.version=version; self.kind=kind; self.id=id; self.payload=payload }
}
public struct VibeQMember: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var name: String
    public init(id: String, name: String) { self.id=id; self.name=name }
}

public enum LensError: LocalizedError {
    case invalid(String), storage(String), provider(String), unavailable(String)
    public var errorDescription: String? { switch self { case .invalid(let s), .storage(let s), .provider(let s), .unavailable(let s): return s } }
}
