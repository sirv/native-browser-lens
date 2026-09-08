import Foundation
import AVFoundation

/// A deliberate microphone session. Audio is never recorded by background capture.
/// The provider's completed text is inserted once; interim text lives outside the editor.
@MainActor
final class SpeechCapture: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isFinishing = false
    @Published private(set) var partial = ""
    var onCompleted: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var readyTimeout: Task<Void, Never>?
    private var finishTimeout: Task<Void, Never>?
    private var completedItems = Set<String>()
    private var tapInstalled = false
    private var generation = UUID()

    func start(apiKey: String, model: String) async throws {
        guard !isRecording && !isConnecting && !isFinishing else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechError.message("Add an OpenAI API key in Settings before dictating.") }
        isConnecting = true; partial = ""; completedItems.removeAll()
        generation = UUID()
        let run = generation
        do {
            let permitted = await AVCaptureDevice.requestAccess(for: .audio)
            guard permitted else { throw SpeechError.message("Microphone access is required for dictation. Enable Native Browser Lens in System Settings → Privacy & Security → Microphone.") }
            var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let connection = URLSession.shared.webSocketTask(with: request)
            socket = connection; connection.resume()
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        guard self?.generation == run else { return }
                        self?.receive(message)
                    }
                } catch {
                    guard !Task.isCancelled, self?.generation == run else { return }
                    self?.fail(error.localizedDescription)
                }
            }
            let config: [String: Any] = ["type": "session.update", "session": [
                "type": "transcription", "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "transcription": ["model": model], "turn_detection": NSNull()
                ]]
            ]]
            // Install acknowledgement continuation before the update can be received.
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                readyTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled, self?.generation == run else { return }
                    self?.fail("The transcription connection did not become ready within 15 seconds.")
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: config)
                    connection.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                        if let error { Task { @MainActor in self?.fail(error.localizedDescription) } }
                    }
                } catch { fail(error.localizedDescription) }
            }
            guard generation == run else { throw CancellationError() }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: format, to: target) else { throw SpeechError.message("The microphone audio format could not be converted to 24 kHz mono PCM.") }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24000 / format.sampleRate) + 64)
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var supplied = false
                var conversionError: NSError?
                converter.convert(to: converted, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                if let conversionError {
                    Task { @MainActor in self?.fail(conversionError.localizedDescription) }; return
                }
                guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
                let audio = Data(bytes: samples, count: Int(converted.frameLength) * 2)
                let message = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(audio.base64EncodedString())\"}"
                connection.send(.string(message)) { [weak self] error in
                    if let error { Task { @MainActor in self?.fail(error.localizedDescription) } }
                }
            }
            tapInstalled = true
            engine.prepare(); try engine.start()
            isConnecting = false; isRecording = true
        } catch {
            cancel()
            throw error
        }
    }

    func finish() {
        guard isRecording else { return }
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        isRecording = false; isFinishing = true
        socket?.send(.string("{\"type\":\"input_audio_buffer.commit\"}")) { [weak self] error in
            if let error { Task { @MainActor in self?.fail(error.localizedDescription) } }
        }
        let run = generation
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, self?.generation == run, self?.isFinishing == true else { return }
            self?.fail("The transcript did not complete. Interim text is preserved below for manual insertion.")
        }
    }

    func cancel() {
        generation = UUID()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        ready?.resume(throwing: CancellationError()); ready = nil
        readyTimeout?.cancel(); finishTimeout?.cancel(); receiver?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        isConnecting = false; isRecording = false; isFinishing = false
    }

    private func fail(_ message: String) {
        ready?.resume(throwing: SpeechError.message(message)); ready = nil
        cancel(); onFailure?(message)
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = object["type"] as? String else { return }
        if type == "session.updated" || type == "transcription_session.updated" {
            readyTimeout?.cancel(); ready?.resume(); ready = nil
        } else if type == "conversation.item.input_audio_transcription.delta" {
            partial += object["delta"] as? String ?? ""
        } else if type == "conversation.item.input_audio_transcription.completed" {
            let itemID = object["item_id"] as? String ?? "single"
            guard completedItems.insert(itemID).inserted else { return }
            let transcript = (object["transcript"] as? String ?? partial).trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { onCompleted?(transcript) }
            partial = ""
            if isFinishing { cancel() }
        } else if type == "error" || type == "conversation.item.input_audio_transcription.failed" {
            let error = object["error"] as? [String: Any]
            fail(error?["message"] as? String ?? "The transcription provider rejected this session.")
        }
    }
}

enum SpeechError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
