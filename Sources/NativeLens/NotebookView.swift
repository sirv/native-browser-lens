import SwiftUI
import AppKit
import LensCore

struct NotebookView: View {
    @ObservedObject var model: LensAppModel
    @ObservedObject private var speech: SpeechCapture
    @State private var tool = "rectangle"
    @State private var rail = "Notes"
    @State private var showCloudReview = false
    @State private var search = ""
    init(model: LensAppModel) { self.model = model; self.speech = model.speech }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Rectangle().fill(LensTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(LensTheme.line).frame(height: 1)
                HSplitView {
                    captureColumn.frame(minWidth: 440, maxWidth: .infinity)
                    evidenceRail.frame(minWidth: 290, idealWidth: 328, maxWidth: 420)
                }
                statusBar
            }
        }
        .foregroundStyle(LensTheme.ink).background(LensTheme.background)
        .frame(minWidth: 1050, minHeight: 680)
        .tint(LensTheme.accent)
        .preferredColorScheme(model.appearance == "system" ? nil : (model.appearance == "light" ? .light : .dark))
        .sheet(isPresented: $model.showSettings) { LensSettingsView(model: model) }
        .sheet(isPresented: $model.showReview) { FilingReviewView(model: model) }
        .sheet(isPresented: $showCloudReview) { CloudReviewView(model: model) }
        .alert("Something needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder").font(.system(size: 24, weight: .light)).foregroundStyle(LensTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lens").font(LensTheme.head)
                    Eyebrow("Browser notebook")
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 26)
            HStack {
                Eyebrow("Workspace")
                Spacer()
                Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(LensTheme.faint).help("Projects and settings")
            }.padding(.horizontal, 20)
            Menu {
                ForEach(model.projects) { project in
                    Button(project.name) { model.selectedProjectID = project.id }
                }
                Divider()
                Button("Manage projects…") { model.showSettings = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(LensTheme.faint)
                    Text(model.projects.first { $0.id == model.selectedProjectID }?.name ?? "Choose project").font(LensTheme.body).lineLimit(1)
                    Spacer(); Image(systemName: "chevron.down").font(.system(size: 10))
                }.padding(11).background(LensTheme.inset, in: RoundedRectangle(cornerRadius: 7))
            }.menuStyle(.borderlessButton).padding(.horizontal, 12).padding(.top, 10)

            Button { _ = model.newObservation() } label: {
                HStack { Image(systemName: "square.and.pencil"); Text("New observation"); Spacer(); Text("⌘N").foregroundStyle(LensTheme.faint) }
            }.buttonStyle(LensButtonStyle()).padding(.horizontal, 12).padding(.top, 12).keyboardShortcut("n")
            HStack {
                Eyebrow("Observations")
                Spacer()
                Text("\(filteredObservations.count)").font(LensTheme.caption).monospacedDigit().foregroundStyle(LensTheme.faint)
            }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
            if model.observations.count > 6 {
                TextField("Find an observation", text: $search).textFieldStyle(.plain).font(LensTheme.detail).padding(10)
                    .background(LensTheme.inset, in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredObservations) { observation in
                        Button { model.selectObservation(observation.id) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: observation.receipt == nil ? "text.bubble" : "checkmark.circle").font(.system(size: 13)).foregroundStyle(LensTheme.faint).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(observation.title).font(LensTheme.detail).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 6) {
                                        Text(Date(timeIntervalSince1970: observation.createdAt / 1000), style: .date)
                                        Text("· \(observation.captures.count) captures")
                                    }.font(LensTheme.caption).foregroundStyle(LensTheme.faint).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedObservationID == observation.id ? LensTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(alignment: .leading) { if model.selectedObservationID == observation.id { Capsule().fill(LensTheme.accent).frame(width: 2, height: 24) } }
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(model.paused ? LensTheme.warn : (model.armedCount > 0 ? LensTheme.ok : LensTheme.dim)).frame(width: 6, height: 6)
                    Text(model.statusText).font(LensTheme.meta).foregroundStyle(LensTheme.soft)
                    Spacer()
                    Button(action: model.togglePause) { Image(systemName: model.paused ? "play" : "pause") }.buttonStyle(.plain).help(model.paused ? "Resume capture" : "Pause capture")
                }
                Text("Two minutes of context.\nOnly your configured projects.").font(LensTheme.caption).foregroundStyle(LensTheme.faint).lineSpacing(3)
            }.padding(16).overlay(alignment: .top) { Rectangle().fill(LensTheme.line).frame(height: 1) }
        }.background(LensTheme.surface)
    }
    private var filteredObservations: [NotebookObservation] {
        model.observations.filter { (model.selectedProjectID == nil || $0.projectId == model.selectedProjectID) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.markdown.localizedCaseInsensitiveContains(search)) }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.tabs, id: \.selfKey) { tab in
                    Button { model.selectedTabKey = model.tabKey(tab) } label: {
                        Text("\(tab.title) · \(tab.mode) · window \(tab.windowId)")
                    }
                }
                if model.tabs.isEmpty { Text("Grant project origins in the Chrome extension") }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(LensTheme.faint)
                    Text(model.selectedTab?.title ?? "Select a Chrome tab").font(LensTheme.detail).lineLimit(1).frame(maxWidth: 230, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(LensTheme.faint)
                }
            }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button { model.capture() } label: { Label(model.capturing ? "Capturing…" : "Capture", systemImage: "viewfinder") }
                .buttonStyle(LensButtonStyle()).disabled(model.selectedTab == nil || model.paused || model.capturing)
                .help("Capture the page before Lens takes focus · ⌘⌥⇧L")
            Button(action: model.dictate) { Image(systemName: speech.isRecording ? "stop.fill" : "mic").frame(width: 15) }
                .buttonStyle(LensButtonStyle(prominent: speech.isRecording)).disabled(speech.isConnecting || speech.isFinishing)
                .help(speech.isRecording ? "Finish dictation" : "Append dictation to this notebook")
            Menu {
                Button("Read local source & documentation") { model.investigate(useCloud: false) }
                Button("Investigate with OpenAI…") { showCloudReview = true }
            } label: { Label(model.investigating ? "Investigating…" : "Investigate", systemImage: "sparkle.magnifyingglass") }
                .menuStyle(.borderlessButton).font(LensTheme.meta).padding(.horizontal, 8).disabled(model.current == nil || model.investigating)
            Button { model.prepareReview() } label: { Label(model.current?.receipt == nil ? "Review & file" : "Review update", systemImage: "arrow.up.right") }
                .buttonStyle(LensButtonStyle(prominent: true)).disabled(model.current == nil || model.filing)
        }.padding(.horizontal, 22).frame(height: 66).background(LensTheme.surface)
    }

    private var captureColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow(model.current == nil ? "A little more context" : "Observation")
                    Spacer()
                    if let receipt = model.current?.receipt, let url = URL(string: receipt.taskUrl) {
                        Link(destination: url) { Label("Open in VibeQ", systemImage: "arrow.up.right") }.font(LensTheme.caption).foregroundStyle(LensTheme.soft)
                    }
                    if model.current != nil { Button(action: model.export) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain).foregroundStyle(LensTheme.faint).help("Export Markdown and reviewed evidence") }
                }
                if let observation = model.current {
                    TextField("Name this observation", text: Binding(get: { model.current?.title ?? "" }, set: { model.edit(title: $0) }), axis: .vertical)
                        .font(LensTheme.hero).tracking(-0.34).textFieldStyle(.plain).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(model.currentProject?.name ?? "Project")
                        Text("/").foregroundStyle(LensTheme.dim)
                        Text("Revision \(observation.draftRevision)")
                        Spacer()
                        Text("Saved locally").foregroundStyle(LensTheme.faint)
                    }.font(LensTheme.caption).foregroundStyle(LensTheme.soft)
                } else {
                    Text("The detail is the story.").font(LensTheme.hero).tracking(-0.34)
                    Text("A visual notebook for what your browser just did.").font(LensTheme.body).foregroundStyle(LensTheme.soft)
                }
            }.padding(24)

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    if model.currentCapture != nil {
                        annotationButton("rectangle", icon: "rectangle", label: "Rectangle")
                        annotationButton("arrow", icon: "arrow.up.right", label: "Arrow")
                        annotationButton("pen", icon: "pencil.tip", label: "Pen")
                        Rectangle().fill(LensTheme.line).frame(width: 1, height: 16).padding(.horizontal, 6)
                        annotationButton("mask", icon: "rectangle.fill", label: "Mask sensitive content")
                        Button(action: model.undoAnnotation) { Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28) }.buttonStyle(.plain).foregroundStyle(LensTheme.faint).disabled(model.currentCapture?.annotations.isEmpty != false).help("Undo last annotation")
                    } else { Eyebrow("Capture canvas").padding(.leading, 6) }
                    Spacer()
                    if let capture = model.currentCapture {
                        Eyebrow(capture.context["coordinateSpace"]?.stringValue == "native-window" ? "Window" : "Viewport")
                    }
                    Button(action: model.toggleVideo) { Image(systemName: model.recordingVideo ? "record.circle.fill" : "video").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(model.recordingVideo ? LensTheme.accent : LensTheme.faint).disabled(model.selectedTab == nil).help(model.videoStatus)
                }.padding(.horizontal, 10).padding(.vertical, 8).background(LensTheme.surface)
                Rectangle().fill(LensTheme.line).frame(height: 1)
                if let capture = model.currentCapture {
                    AnnotationCanvas(capture: capture, tool: tool, add: model.annotate).frame(minHeight: 260, maxHeight: .infinity)
                } else {
                    CaptureEmptyCanvas(connected: model.selectedTab != nil, capture: { model.capture() }, settings: { model.showSettings = true }).frame(minHeight: 300, maxHeight: .infinity)
                }
                if let capture = model.currentCapture {
                    HStack(spacing: 8) {
                        Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(LensTheme.faint)
                        Text(capture.identity.url).font(LensTheme.caption).lineLimit(1).foregroundStyle(LensTheme.soft)
                        Spacer()
                        Text(Date(timeIntervalSince1970: capture.identity.capturedAt / 1000), style: .time).font(LensTheme.caption).monospacedDigit().foregroundStyle(LensTheme.faint)
                    }.padding(11).background(LensTheme.surface).overlay(alignment: .top) { Rectangle().fill(LensTheme.line).frame(height: 1) }
                }
            }.clipShape(RoundedRectangle(cornerRadius: LensTheme.radius)).overlay(RoundedRectangle(cornerRadius: LensTheme.radius).strokeBorder(LensTheme.line)).padding(.horizontal, 24)

            if let captures = model.current?.captures, !captures.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(captures.enumerated()), id: \.element.id) { index, capture in
                            Button { model.selectedCaptureID = capture.id } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    if let path = capture.screenshotPath, let image = NSImage(contentsOfFile: path) {
                                        Image(nsImage: image).resizable().scaledToFill().frame(width: 94, height: 55).clipped()
                                    } else { Image(systemName: "text.alignleft").frame(width: 94, height: 55).background(LensTheme.inset) }
                                    Text("\(index + 1)  ·  \(capture.events.count) events").font(LensTheme.caption).foregroundStyle(LensTheme.faint)
                                }.padding(6).background(LensTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.currentCapture?.id == capture.id ? LensTheme.accent : LensTheme.line))
                            }.buttonStyle(.plain)
                        }
                        Button { model.capture() } label: { Image(systemName: "plus").frame(width: 40, height: 72) }.buttonStyle(.plain).foregroundStyle(LensTheme.faint).disabled(model.selectedTab == nil || model.capturing)
                    }.padding(.vertical, 2)
                }.padding(.horizontal, 24).padding(.top, 16).frame(height: 105)
            }
            if let capture = model.currentCapture, let path = capture.context["videoPath"]?.stringValue {
                HStack {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label("Play \(Int(capture.context["videoSeconds"]?.doubleValue ?? 0))s recording", systemImage: "play.circle") }.buttonStyle(.plain).font(LensTheme.caption).foregroundStyle(LensTheme.soft)
                    Spacer()
                    Toggle("Reviewed for export", isOn: Binding(get: { model.currentCapture?.context["videoReviewed"]?.boolValue == true }, set: model.setVideoReviewed)).font(LensTheme.caption).toggleStyle(.checkbox)
                }.padding(.horizontal, 24).padding(.top, 8)
            }
            Spacer(minLength: 20)
        }.background(LensTheme.background)
    }
    private func annotationButton(_ value: String, icon: String, label: String) -> some View {
        Button { tool = value } label: { Image(systemName: icon).frame(width: 28, height: 28).background(tool == value ? LensTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 5)) }
            .buttonStyle(.plain).foregroundStyle(tool == value ? LensTheme.accent : LensTheme.faint).help(label).accessibilityLabel(label)
    }

    private var evidenceRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                ForEach(["Notes", "Evidence", "Findings"], id: \.self) { item in
                    Button { rail = item } label: {
                        Text(item).font(LensTheme.meta).foregroundStyle(rail == item ? LensTheme.ink : LensTheme.faint).padding(.vertical, 20)
                            .overlay(alignment: .bottom) { if rail == item { Rectangle().fill(LensTheme.accent).frame(height: 2) } }
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 22).overlay(alignment: .bottom) { Rectangle().fill(LensTheme.line).frame(height: 1) }
            if rail == "Notes" { notes }
            else if rail == "Evidence" { evidence }
            else { findings }
        }.background(LensTheme.surface)
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Eyebrow("Your notebook"); Spacer(); Eyebrow("Markdown") }.padding(.horizontal, 22).padding(.top, 23).padding(.bottom, 18)
            if model.current != nil {
                ZStack(alignment: .topLeading) {
                    if model.current?.markdown.isEmpty == true {
                        Text("What happened?\nWhat did you expect?").font(LensTheme.body).foregroundStyle(LensTheme.faint).lineSpacing(6).padding(.horizontal, 5).padding(.top, 1).allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(get: { model.current?.markdown ?? "" }, set: { model.edit(markdown: $0) }))
                        .font(LensTheme.body).lineSpacing(5).scrollContentBackground(.hidden).background(.clear)
                        .accessibilityLabel("Observation Markdown")
                }.padding(.horizontal, 17).frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Start with a capture.\nOr start with a thought.").font(LensTheme.head).lineSpacing(4)
                    Text("Write in Markdown, dictate a thought, and collect several moments in one observation.").font(LensTheme.body).foregroundStyle(LensTheme.soft).lineSpacing(3)
                    Button { _ = model.newObservation() } label: { Label("Write a note", systemImage: "square.and.pencil") }.buttonStyle(LensButtonStyle())
                }.padding(.horizontal, 22)
                Spacer()
            }
            if let suggestion = model.suggestedDraft, model.suggestedDraftObservationID == model.current?.id {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("Suggested report")
                    ScrollView { Text(suggestion).font(LensTheme.detail).foregroundStyle(LensTheme.soft).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                    HStack { Button("Use this draft", action: model.applySuggestedDraft).buttonStyle(LensButtonStyle()); Button("Dismiss") { model.suggestedDraft = nil }.buttonStyle(.plain).font(LensTheme.caption).foregroundStyle(LensTheme.faint) }
                }.padding(18).background(LensTheme.inset)
            }
            if speech.isRecording || speech.isConnecting || speech.isFinishing || !speech.partial.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(LensTheme.accent)
                        Text(speech.isConnecting ? "Connecting microphone…" : (speech.isFinishing ? "Finishing transcript…" : (speech.isRecording ? "Listening" : "Unfinished transcript"))).font(LensTheme.meta)
                        Spacer()
                        if speech.isRecording { Button("Finish", action: speech.finish).buttonStyle(.plain).font(LensTheme.meta) }
                    }
                    if !speech.partial.isEmpty { Text(speech.partial).font(LensTheme.detail).foregroundStyle(LensTheme.soft).textSelection(.enabled).lineLimit(8) }
                    if !speech.isRecording && !speech.isConnecting && !speech.isFinishing && !speech.partial.isEmpty { Button("Insert interim text", action: model.insertPartialTranscript).buttonStyle(LensButtonStyle()) }
                }.padding(18).background(LensTheme.inset)
            }
            HStack(spacing: 8) {
                Image(systemName: "mic").foregroundStyle(LensTheme.faint)
                Text("Your words stay editable.").font(LensTheme.caption).foregroundStyle(LensTheme.faint)
                Spacer()
            }.padding(22)
        }
    }
    private var evidence: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Eyebrow("Capture coverage")
                if let capture = model.currentCapture {
                    HStack(spacing: 22) {
                        Button { proxy.scrollTo("event-timeline", anchor: .top) } label: { VStack(alignment: .leading, spacing: 4) { Text("\(capture.events.count)").font(LensTheme.hero).monospacedDigit(); Text("events below").font(LensTheme.caption).foregroundStyle(LensTheme.faint) } }.buttonStyle(.plain)
                        Button { proxy.scrollTo("coverage-notes", anchor: .top) } label: { VStack(alignment: .leading, spacing: 4) { Text("\(capture.gaps.count)").font(LensTheme.hero).monospacedDigit(); Text("coverage notes").font(LensTheme.caption).foregroundStyle(LensTheme.faint) } }.buttonStyle(.plain)
                    }
                    Color.clear.frame(height: 0).id("coverage-notes")
                    ForEach(capture.gaps) { gap in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(gap.channel).font(LensTheme.meta).fontWeight(.medium)
                            Text(gap.reason).font(LensTheme.detail).foregroundStyle(LensTheme.soft).fixedSize(horizontal: false, vertical: true)
                        }.padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(LensTheme.warn.opacity(0.6)).frame(width: 2) }
                    }
                    Rectangle().fill(LensTheme.line).frame(height: 1)
                    DisclosureGroup("Page context") { Text(JSONValue.object(capture.context).pretty).font(.system(size: 11, design: .monospaced)).foregroundStyle(LensTheme.soft).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(LensTheme.meta)
                    Eyebrow("Timeline").id("event-timeline")
                    ForEach(capture.events.sorted { $0.timestamp > $1.timestamp }) { event in
                        DisclosureGroup {
                            Text(JSONValue.object(event.data).pretty).font(.system(size: 11, design: .monospaced)).foregroundStyle(LensTheme.soft).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(event.kind).font(LensTheme.meta).lineLimit(1)
                                Spacer()
                                Text(Date(timeIntervalSince1970: event.timestamp / 1000), style: .time).font(LensTheme.caption).monospacedDigit().foregroundStyle(LensTheme.faint)
                            }
                        }
                    }
                } else { Text("Network, console, storage, and coverage details appear beside each capture.").font(LensTheme.body).foregroundStyle(LensTheme.soft).lineSpacing(3) }
            }.padding(22)
        }
        }
    }
    private var findings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow("What the evidence says")
                if model.current?.findings.isEmpty != false {
                    Text("Investigate an observation to connect the page to source code and documented behaviour.").font(LensTheme.body).foregroundStyle(LensTheme.soft).lineSpacing(3)
                    Text("Facts, expectations, and hypotheses remain distinct.").font(LensTheme.detail).foregroundStyle(LensTheme.faint)
                }
                ForEach(model.current?.findings ?? []) { finding in
                    VStack(alignment: .leading, spacing: 9) {
                        Eyebrow(finding.kind)
                        Text(finding.text).font(LensTheme.body).foregroundStyle(LensTheme.soft).lineSpacing(3).textSelection(.enabled)
                        if let source = finding.source {
                            if navigableSource(source) {
                                Button { openSource(source) } label: { Label(source, systemImage: "arrow.up.right").lineLimit(2).multilineTextAlignment(.leading) }.buttonStyle(.plain).font(LensTheme.caption).foregroundStyle(LensTheme.accent)
                            } else { Text(source).font(LensTheme.caption).foregroundStyle(LensTheme.faint).textSelection(.enabled) }
                        }
                    }.padding(.bottom, 18).overlay(alignment: .bottom) { Rectangle().fill(LensTheme.line).frame(height: 1) }
                }
            }.padding(22)
        }
    }
    private func navigableSource(_ source: String) -> Bool {
        if source.hasPrefix("event:") || model.current?.captures.contains(where: { $0.id == source }) == true { return true }
        if let url = URL(string: source), ["http", "https"].contains(url.scheme ?? "") { return true }
        let path = source.split(separator: ":").first.map(String.init) ?? source
        let full = path.hasPrefix("/") ? path : (model.currentProject?.repositoryPath ?? "") + "/" + path
        return FileManager.default.fileExists(atPath: full)
    }
    private func openSource(_ source: String) {
        if source.hasPrefix("event:") { rail = "Evidence"; return }
        if model.current?.captures.contains(where: { $0.id == source }) == true { model.selectedCaptureID = source; rail = "Evidence"; return }
        if let url = URL(string: source), ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        else {
            let path = source.split(separator: ":").first.map(String.init) ?? source
            if path.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else if let repository = model.currentProject?.repositoryPath { NSWorkspace.shared.open(URL(fileURLWithPath: repository).appendingPathComponent(path)) }
        }
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.capturing ? "viewfinder" : "internaldrive").font(.system(size: 10))
            Text(model.notice).lineLimit(1)
            Spacer()
            if model.unsavedCaptureCount > 0 {
                Button("Retry saving \(model.unsavedCaptureCount) retained captures", action: model.retryCaptureSaves).buttonStyle(.plain).foregroundStyle(LensTheme.accent)
            }
            if model.recordingVideo { Text("30s local video").foregroundStyle(LensTheme.accent) }
            Text("⌘⌥⇧L to capture").foregroundStyle(LensTheme.faint)
        }.font(LensTheme.caption).foregroundStyle(LensTheme.soft).padding(.horizontal, 22).frame(height: 33).background(LensTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(LensTheme.line).frame(height: 1) }
    }
}

private extension TabStatus { var selfKey: String { "\(clientId ?? "default"):\(tabId)" } }
