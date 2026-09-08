import SwiftUI
import AppKit
import LensCore
import Carbon

@main
@MainActor
struct NativeLensApp: App {
    @NSApplicationDelegateAdaptor(LensAppDelegate.self) private var delegate
    @StateObject private var model = LensAppModel()
    var body: some Scene {
        WindowGroup("Native Browser Lens") {
            NotebookView(model: model)
                .onAppear { let appModel = model; LensShortcuts.capture = { [weak appModel] in appModel?.capture(preferForeground: true) } }
        }
        .defaultSize(width: 1360, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New observation") { _ = model.newObservation() }.keyboardShortcut("n") }
            CommandGroup(after: .newItem) {
                Button("Capture selected tab") { model.capture() }.keyboardShortcut("l", modifiers: [.command, .option, .shift])
                Button("Append dictation") { model.dictate() }.keyboardShortcut("d", modifiers: [.command, .option])
                Button("Export observation") { model.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model.showSettings = true; model.reveal() }.keyboardShortcut(",") }
        }
        MenuBarExtra {
            Text(model.statusText)
            if model.recordingVideo { Text(model.videoStatus) }
            Divider()
            Button("Capture page  ⌘⌥⇧L") { model.capture(preferForeground: true) }.disabled(model.paused || model.capturing)
            Button("Open notebook") { model.reveal() }
            Button(model.paused ? "Resume capture" : "Pause capture", action: model.togglePause)
            Divider()
            Button("Settings…") { model.showSettings = true; model.reveal() }
            Button("Quit Lens") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.capturing ? "viewfinder.circle.fill" : (model.paused ? "pause.circle" : (model.recordingVideo ? "record.circle" : "viewfinder.circle")))
                .accessibilityLabel("Native Browser Lens, \(model.statusText)")
        }
    }
}

@MainActor enum LensShortcuts { static var capture: (() -> Void)? }

final class LensAppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.id == 1 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { LensShortcuts.capture?() }
            return noErr
        }, 1, &event, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4C454E53), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
