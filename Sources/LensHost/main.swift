import Foundation
import LensCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

let mailbox = BridgeMailbox()
let clientId = UUID().uuidString
let outputLock = NSLock()
func emit(_ message: WireMessage) throws {
    let frame = try NativeFraming.encode(message)
    outputLock.lock(); defer { outputLock.unlock() }
    try FileHandle.standardOutput.write(contentsOf: frame)
}
do {
    try mailbox.register(clientId: clientId)
    defer { mailbox.unregister(clientId: clientId) }
    let commands = try mailbox.watchCommands(clientId: clientId, queue: DispatchQueue(label: "lens.host.commands")) {
        do { for message in try mailbox.commands(clientId: clientId) { try emit(message) } }
        catch { /* Broken pipe is handled by the stdin reader's close. No payload logging. */ }
    }
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let message = try NativeFraming.next(buffer: &buffer) {
            if message.kind == "hello" { try emit(WireMessage(kind: "configure", payload: .object(["projects": try .from(mailbox.configuration())]))) }
            try mailbox.receive(message, clientId: clientId)
        }
    }
    commands.cancel()
} catch {
    FileHandle.standardError.write(Data("Native Browser Lens host stopped: invalid input or unavailable local storage.\n".utf8))
    exit(1)
}
