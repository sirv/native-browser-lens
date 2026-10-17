import Foundation
#if os(Linux)
import Glibc
import CLinux
#else
import Darwin
#endif

/// File queues provide persistence; filesystem notifications wake consumers without periodic polling.
public final class BridgeWatch {
    #if os(Linux)
    private let source: DispatchSourceRead
    fileprivate init(directory: URL, queue: DispatchQueue, handler: @escaping () -> Void) throws {
        let descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else { throw LensError.storage("Could not open the local evidence watcher") }
        guard inotify_add_watch(descriptor, directory.path, UInt32(IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF)) >= 0 else {
            close(descriptor)
            throw LensError.storage("Could not watch the local evidence bridge")
        }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while Glibc.read(descriptor, &buffer, buffer.count) > 0 {}
            handler()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        queue.async(execute: DispatchWorkItem(block: handler))
    }
    #else
    private let source: DispatchSourceFileSystemObject
    fileprivate init(directory: URL, queue: DispatchQueue, handler: @escaping () -> Void) throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw LensError.storage("Could not watch the local evidence bridge") }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        queue.async(execute: DispatchWorkItem(block: handler))
    }
    #endif
    public func cancel() { source.cancel() }
    deinit { source.cancel() }
}

public enum LensPaths {
    // Bundled Linux launches use ld.so; Bundle.main can identify the loader instead of this helper.
    public static var executableDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent() }
    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["LENS_DATA_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        #if os(Linux)
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        return URL(fileURLWithPath: base ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path, isDirectory: true).appendingPathComponent("native-browser-lens", isDirectory: true)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Native Browser Lens", isDirectory: true)
        #endif
    }
}

/// Private durable transport. Each extension process owns a queue; no browser profile can consume another queue.
public final class BridgeMailbox {
    public let root: URL
    private let queueLock = NSRecursiveLock()
    private var inboxFiles: [String: URL] = [:]
    private var inboxIDs: [String: String] = [:]
    private var selections: [String: (signature: JSONValue, epoch: String)] = [:]
    public init(root: URL = LensPaths.defaultRoot) { self.root = root }
    private var bridge: URL { root.appendingPathComponent("bridge", isDirectory: true) }
    private func directory(_ path: String) throws -> URL {
        let url = bridge.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func write(_ message: WireMessage, to directory: URL, replacing nameOverride: String? = nil) throws {
        let bytes = try JSONEncoder().encode(message)
        guard bytes.count <= 1_048_576 else { throw LensError.invalid("Bridge message exceeds 1 MiB") }
        let name = nameOverride ?? String(format: "%020.0f", nowMilliseconds()*1000) + "-" + UUID().uuidString + ".json"
        let target = directory.appendingPathComponent(name)
        try bytes.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    public func saveConfiguration(projects: [ProjectProfile]) throws {
        _ = try directory("inbox")
        let data = try JSONEncoder().encode(projects)
        try data.write(to: bridge.appendingPathComponent("projects.json"), options: .atomic)
        try send(kind: "configure", payload: .object(["projects": try .from(projects)]))
    }
    public func configuration() -> [ProjectProfile] { (try? JSONDecoder().decode([ProjectProfile].self, from: Data(contentsOf: bridge.appendingPathComponent("projects.json")))) ?? [] }
    public func connectedClientIDs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory("clients"), includingPropertiesForKeys: nil).filter { url in
            guard UUID(uuidString: url.lastPathComponent) != nil else { return false }
            let owner = url.appendingPathComponent(".owner-pid")
            guard FileManager.default.fileExists(atPath: owner.path) else { return true }
            guard let value = try? String(contentsOf: owner, encoding: .utf8), let pid = Int32(value), pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }.map(\.lastPathComponent).sorted()
    }
    public func send(kind: String, payload: JSONValue) throws {
        let clients = try directory("clients")
        let available = try connectedClientIDs().map { clients.appendingPathComponent($0) }
        let requested = payload["clientId"]?.stringValue
        if ["capture", "snapshot", "resumeTab"].contains(kind), requested == nil, available.count != 1 { throw LensError.invalid("Select a connected browser profile before capturing") }
        let targets = available.filter { requested == nil || requested == $0.lastPathComponent }
        if ["capture", "snapshot", "resumeTab"].contains(kind), targets.isEmpty { throw LensError.unavailable("That browser profile is no longer connected") }
        for client in targets {
            try write(WireMessage(kind: kind, payload: payload), to: client)
        }
    }
    public func register(clientId: String) throws {
        guard UUID(uuidString: clientId) != nil else { throw LensError.invalid("Invalid native client identity") }
        let dir = try directory("clients/" + clientId)
        let owner = dir.appendingPathComponent(".owner-pid")
        try String(ProcessInfo.processInfo.processIdentifier).write(to: owner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path)
        try write(WireMessage(kind: "configure", payload: .object(["projects": try .from(configuration())])), to: dir)
    }
    public func unregister(clientId: String) {
        guard UUID(uuidString: clientId) != nil else { return }
        try? receive(WireMessage(kind: "status", payload: .object(["tabs": .array([])])), clientId: clientId)
        try? FileManager.default.removeItem(at: bridge.appendingPathComponent("clients/" + clientId))
    }
    public func receive(_ message: WireMessage, clientId: String? = nil) throws {
        queueLock.lock(); defer { queueLock.unlock() }
        guard message.version == 1 else { throw LensError.invalid("Unsupported bridge version") }
        var tagged = message
        if let clientId, var payload = message.payload.objectValue {
            payload["clientId"] = .string(clientId)
            if let tabs = payload["tabs"]?.arrayValue { payload["tabs"] = .array(tabs.map { tab in var values = tab.objectValue ?? [:]; values["clientId"] = .string(clientId); return .object(values) }) }
            if var tab = payload["tab"]?.objectValue { tab["clientId"] = .string(clientId); payload["tab"] = .object(tab) }
            if var identity = payload["identity"]?.objectValue { identity["clientId"] = .string(clientId); payload["identity"] = .object(identity) }
            if message.kind == "status" {
                let selected = (payload["tabs"]?.arrayValue ?? []).filter { $0["selected"]?.boolValue == true }.map { tab in
                    JSONValue.array(["projectId", "windowId", "tabId", "documentId", "title", "mode"].map { tab[$0] ?? .null })
                }.sorted { $0.pretty < $1.pretty }
                let signature = JSONValue.array(selected)
                let epoch = selections[clientId].flatMap { $0.signature == signature ? $0.epoch : nil } ?? UUID().uuidString
                selections[clientId] = (signature, epoch)
                // Keep evidence of a switch even if queued statuses coalesce back to the original tab.
                payload["selectionEpoch"] = .string(epoch)
            }
            tagged.payload = .object(payload)
        }
        let statusName = message.kind == "status" && clientId.flatMap(UUID.init(uuidString:)) != nil ? "status-" + clientId! + ".json" : nil
        try write(tagged, to: directory("inbox"), replacing: statusName)
    }
    private func drainDirectory(_ directory: URL) throws -> [WireMessage] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [WireMessage] = []
        for queued in files.prefix(256) {
            // Claim by rename before reading. A concurrent status replacement then
            // stays queued instead of being removed with the version we consumed.
            let file: URL
            if queued.lastPathComponent.hasPrefix(".claimed-") { file = queued }
            else {
                file = directory.appendingPathComponent(".claimed-" + UUID().uuidString + "-" + queued.lastPathComponent)
                do { try FileManager.default.moveItem(at: queued, to: file) }
                catch where !FileManager.default.fileExists(atPath: queued.path) { continue }
            }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { try FileManager.default.removeItem(at: file); continue }
            do {
                let message = try JSONDecoder().decode(WireMessage.self, from: Data(contentsOf: file))
                guard message.version == 1 else { throw LensError.invalid("Unsupported bridge version") }
                result.append(message)
            } catch {
                result.append(WireMessage(kind: "error", payload: .object(["message": .string("Discarded invalid native bridge message")])) )
            }
            try FileManager.default.removeItem(at: file)
        }
        return result
    }
    public func drain() throws -> [WireMessage] { try drainDirectory(directory("inbox")) }
    private func inboxOrderKey(_ file: URL) -> String {
        let claimed = file.lastPathComponent.hasPrefix(".claimed-")
        let name = claimed ? String(file.lastPathComponent.dropFirst(".claimed-".count)) : file.lastPathComponent
        if name.hasPrefix("status-"), UUID(uuidString: String(name.dropFirst("status-".count).dropLast(".json".count))) != nil {
            // Legacy fixed-name claims precede numbered generations. The latest
            // coalesced status has not been claimed yet and must replay last.
            return String(name.dropLast(".json".count)) + (claimed ? "-00000000000000000000" : "~")
        }
        return name
    }
    private func inboxClaimName(_ queued: URL, existing: [URL]) -> String {
        guard queued.lastPathComponent.hasPrefix("status-") else { return ".claimed-" + queued.lastPathComponent }
        let prefix = ".claimed-" + queued.deletingPathExtension().lastPathComponent + "-"
        let previous = existing.compactMap { file -> Double? in
            guard file.lastPathComponent.hasPrefix(prefix) else { return nil }
            return Double(file.lastPathComponent.dropFirst(prefix.count).prefix(20))
        }.max() ?? 0
        // A generation survives restarts and clock rollback; UUID prevents two
        // consumers from claiming the same destination. Capture names stay intact.
        let generation = max(nowMilliseconds() * 1000, previous + 1)
        return prefix + String(format: "%020.0f", generation) + "-" + UUID().uuidString + ".json"
    }
    /// Durable inbox delivery. Capture envelopes remain until the notebook has
    /// persisted the complete observation and explicitly acknowledges their IDs.
    public func pending(excluding: Set<String> = []) throws -> [WireMessage] {
        queueLock.lock(); defer { queueLock.unlock() }
        let inbox = try directory("inbox")
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }.sorted {
            inboxOrderKey($0) < inboxOrderKey($1)
        }
        var messages: [WireMessage] = []
        for queued in files {
            if let id = inboxIDs[queued.path], excluding.contains(id) { continue }
            let file: URL
            if queued.lastPathComponent.hasPrefix(".claimed-") { file = queued }
            else {
                file = inbox.appendingPathComponent(inboxClaimName(queued, existing: files))
                do { try FileManager.default.moveItem(at: queued, to: file) }
                catch where !FileManager.default.fileExists(atPath: queued.path) { continue }
            }
            let message: WireMessage
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw LensError.invalid("Oversized native message") }
                message = try JSONDecoder().decode(WireMessage.self, from: Data(contentsOf: file))
                guard message.version == 1 else { throw LensError.invalid("Unsupported native message") }
            } catch {
                let id = stableUUID(file.lastPathComponent)
                let poison = WireMessage(kind: "error", id: id, payload: .object(["message": .string("Invalid native envelope retained until its coverage note is saved"), "poison": .bool(true)]))
                inboxFiles[id] = file; inboxIDs[file.path] = id
                if !excluding.contains(id) { messages.append(poison) }
                if messages.count >= 256 { break }; continue
            }
            inboxFiles[message.id] = file; inboxIDs[file.path] = message.id
            if !excluding.contains(message.id) { messages.append(message) }
            if messages.count >= 256 { break }
        }
        return messages
    }
    public func acknowledge(_ messageIDs: Set<String>) throws {
        queueLock.lock(); defer { queueLock.unlock() }
        for id in messageIDs {
            guard let file = inboxFiles[id] else { continue }
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            inboxIDs.removeValue(forKey: file.path); inboxFiles.removeValue(forKey: id)
        }
    }
    public func watchInbox(queue: DispatchQueue, handler: @escaping () -> Void) throws -> BridgeWatch {
        try BridgeWatch(directory: directory("inbox"), queue: queue, handler: handler)
    }
    public func watchCommands(clientId: String, queue: DispatchQueue, handler: @escaping () -> Void) throws -> BridgeWatch {
        guard UUID(uuidString: clientId) != nil else { throw LensError.invalid("Invalid client identity") }
        return try BridgeWatch(directory: directory("clients/" + clientId), queue: queue, handler: handler)
    }
    public func commands(clientId: String) throws -> [WireMessage] {
        guard UUID(uuidString: clientId) != nil else { throw LensError.invalid("Invalid client identity") }
        return try drainDirectory(directory("clients/" + clientId))
    }
}

public enum NativeFraming {
    public static func encode(_ message: WireMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= 1_048_576 else { throw LensError.invalid("Native frame too large") }
        var size = UInt32(body.count).littleEndian
        var result = Data(bytes: &size, count: 4); result.append(body); return result
    }
    public static func next(buffer: inout Data) throws -> WireMessage? {
        guard buffer.count >= 4 else { return nil }
        let size = buffer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard size > 0, size <= 1_048_576 else { throw LensError.invalid("Invalid native frame length") }
        guard buffer.count >= 4 + Int(size) else { return nil }
        let body = Data(buffer.dropFirst(4).prefix(Int(size)))
        buffer.removeFirst(4 + Int(size))
        let message = try JSONDecoder().decode(WireMessage.self, from: body)
        guard message.version == 1 else { throw LensError.invalid("Unsupported native protocol") }
        return message
    }
}
