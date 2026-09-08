import SwiftUI
import AppKit
import LensCore

struct CloudReviewView: View {
    @ObservedObject var model: LensAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var reviewed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 7) { Eyebrow("OpenAI / Evidence review"); Text("Choose what leaves your Mac.").font(LensTheme.head) }; Spacer(); Button("Cancel") { dismiss() }.buttonStyle(LensButtonStyle()) }
            Text("The notebook text and selected technical evidence will be sanitized and sent to OpenAI. Review each image and use the mask tool for anything private. Recordings and background buffers stay local.").font(LensTheme.body).foregroundStyle(LensTheme.soft).lineSpacing(3)
            Text("Up to 2 images, each up to 4 MB. Any excluded images appear as coverage notes.").font(LensTheme.detail).foregroundStyle(LensTheme.faint)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("Notebook text")
                    Text(model.current?.markdown ?? "").font(LensTheme.detail).foregroundStyle(LensTheme.soft).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Eyebrow("Capture evidence")
                    ForEach(model.current?.captures ?? []) { capture in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: Binding(get: { selected.contains(capture.id) }, set: { if $0 { selected.insert(capture.id) } else { selected.remove(capture.id) }; reviewed = false })).labelsHidden().toggleStyle(.checkbox)
                            if let path = capture.screenshotPath, let image = NSImage(contentsOfFile: path) {
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Image(nsImage: image).resizable().scaledToFit().frame(width: 120, height: 78).background(LensTheme.background) }.buttonStyle(.plain).help("Open full-size reviewed image")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(capture.identity.title).font(LensTheme.body).lineLimit(2)
                                Text("\(capture.events.count) events · \(capture.annotations.filter { $0.kind == "mask" }.count) masks").font(LensTheme.caption).foregroundStyle(LensTheme.faint)
                                Text(capture.identity.url).font(LensTheme.caption).foregroundStyle(LensTheme.soft).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.padding(12).lensTile()
                    }
                }
            }.frame(maxHeight: 300)
            Toggle("I reviewed the notebook and selected screenshots for private content", isOn: $reviewed).toggleStyle(.checkbox).font(LensTheme.detail)
            HStack { Text("\(selected.count) captures selected").font(LensTheme.meta).foregroundStyle(LensTheme.faint); Spacer(); Button("Investigate with OpenAI") { model.selectCloudCaptures(selected); dismiss(); model.investigate(useCloud: true) }.buttonStyle(LensButtonStyle(prominent: true)).disabled(!reviewed) }
        }.padding(26).frame(width: 640).foregroundStyle(LensTheme.ink).background(LensTheme.background).tint(LensTheme.accent)
            .onAppear { selected = Set(model.current?.captures.filter { $0.context["includeInAI"]?.boolValue == true }.map(\.id) ?? []) }
            .onChange(of: model.current?.editVersion) { _, _ in reviewed = false }
            .onChange(of: model.current?.captures.count) { _, _ in reviewed = false }
            .onChange(of: model.current?.id) { _, _ in dismiss() }
    }
}

struct FilingReviewView: View {
    @ObservedObject var model: LensAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var observation: NotebookObservation?
    @State private var approved = false
    @State private var manifestExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Eyebrow("VibeQ / Review"); Text(model.filingSnapshot == nil ? "Ready for someone to pick up." : "This reviewed revision is saved.").font(LensTheme.head) }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(LensButtonStyle()).disabled(model.filing)
            }
            if let observation {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) { Text(observation.title).font(LensTheme.head); Text("Revision \(observation.draftRevision) · \(model.projects.first { $0.id == observation.projectId }?.name ?? "Project")").font(LensTheme.detail).foregroundStyle(LensTheme.faint) }
                    Spacer()
                    Text("\(observation.captures.count) captures").font(LensTheme.meta).foregroundStyle(LensTheme.soft)
                }
                ScrollView { Text(observation.markdown.isEmpty ? "The report has no written description yet." : observation.markdown).font(LensTheme.body).foregroundStyle(LensTheme.soft).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(16).frame(minHeight: 120, maxHeight: 220).background(LensTheme.surface, in: RoundedRectangle(cornerRadius: LensTheme.radius)).overlay(RoundedRectangle(cornerRadius: LensTheme.radius).strokeBorder(LensTheme.line))
                HStack {
                    Eyebrow("Assign to")
                    Picker("Owner", selection: $model.assigneeID) {
                        Text("Leave unassigned").tag("")
                        ForEach(model.members) { Text($0.name).tag($0.id) }
                    }.labelsHidden().disabled(model.filingSnapshot != nil || model.filing || model.filingProgress["receipt"]?.state == "completed")
                    Spacer()
                }
                DisclosureGroup(isExpanded: $manifestExpanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The Markdown report and sanitized evidence manifest are included.").font(LensTheme.detail).foregroundStyle(LensTheme.soft)
                            ForEach(observation.captures) { capture in
                                HStack {
                                    Image(systemName: "photo").foregroundStyle(LensTheme.faint)
                                    Text(capture.identity.title).font(LensTheme.detail).lineLimit(1)
                                    Spacer()
                                    if let path = capture.screenshotPath { Button("View") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(.plain).font(LensTheme.caption).foregroundStyle(LensTheme.accent) }
                                    if capture.context["videoReviewed"]?.boolValue == true { Image(systemName: "video").help("Reviewed recording included") }
                                }
                            }
                        }.padding(.vertical, 10)
                    }.frame(maxHeight: 150)
                } label: { Text("Review attachments").font(LensTheme.meta) }
                if !model.filingProgress.isEmpty {
                    FilingProgressView(progress: model.filingProgress, retry: { model.retryFiling() }, retryEnabled: !model.filing && model.filingProgress.values.contains { $0.state == "failed" })
                }
                if model.filingProgress["receipt"]?.state == "completed" {
                    HStack {
                        Text("Task and attachments confirmed.").font(LensTheme.detail).foregroundStyle(LensTheme.soft)
                        Spacer()
                        if let receipt = model.current?.receipt, let url = URL(string: receipt.taskUrl) { Link("Open in VibeQ", destination: url).font(LensTheme.meta) }
                        Button("Done") { dismiss() }.buttonStyle(LensButtonStyle(prominent: true))
                    }
                } else if model.filingSnapshot == nil {
                    Toggle("I reviewed the report, assignment, and attachments", isOn: $approved).toggleStyle(.checkbox).font(LensTheme.detail)
                    HStack {
                        Text("A durable receipt confirms the outcome.").font(LensTheme.caption).foregroundStyle(LensTheme.faint)
                        Spacer()
                        Button(observation.receipt == nil ? "File defect" : "File reviewed update") { model.fileReviewed(observation: observation, assigneeID: model.assigneeID) }.buttonStyle(LensButtonStyle(prominent: true)).disabled(!approved || model.filing || observation.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else if !model.filing {
                    Text("Retry recovers this exact reviewed revision before another update is sent.").font(LensTheme.caption).foregroundStyle(LensTheme.faint)
                }
            }
        }.padding(26).frame(width: 650).foregroundStyle(LensTheme.ink).background(LensTheme.background).tint(LensTheme.accent)
            .onAppear { observation = model.filingSnapshot ?? model.current }
    }
}

/// Native adaptation of beUI's compact agent todo-list disclosure. Every state
/// comes from a VibeQClient progress event, including failures and retry recovery.
struct FilingProgressView: View {
    let progress: [String: FilingProgress]
    let retry: () -> Void
    let retryEnabled: Bool
    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let stages = [("prepare", "Prepare reviewed revision"), ("reconcile", "Check existing submission"), ("attachments", "Upload reviewed evidence"), ("submit", "Record defect in VibeQ"), ("receipt", "Confirm durable receipt")]
    private var completed: Int { stages.filter { progress[$0.0]?.state == "completed" }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: completed == stages.count ? "checkmark.circle" : "checklist").foregroundStyle(completed == stages.count ? LensTheme.ok : LensTheme.faint)
                    Text(completed == stages.count ? "Defect filed" : "Filing to VibeQ").font(LensTheme.meta).fontWeight(.medium)
                    Spacer()
                    Text("\(completed)/\(stages.count)").font(LensTheme.caption).monospacedDigit().foregroundStyle(LensTheme.faint)
                    Image(systemName: "chevron.down").font(.system(size: 10)).rotationEffect(.degrees(expanded ? 0 : -90)).foregroundStyle(LensTheme.faint)
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Filing to VibeQ, \(completed) of \(stages.count) stages completed")
            if expanded {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(stages, id: \.0) { stage in
                        let event = progress[stage.0]
                        HStack(alignment: .top, spacing: 10) {
                            FilingStatusIcon(state: event?.state ?? "pending", fraction: (event?.total ?? 0) > 0 ? Double(event?.completed ?? 0) / Double(event!.total) : nil).frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(stage.1).font(LensTheme.detail).foregroundStyle(event?.state == "pending" || event == nil ? LensTheme.faint : LensTheme.ink)
                                if let event, !event.detail.isEmpty { Text(event.detail).font(LensTheme.caption).foregroundStyle(event.state == "failed" ? LensTheme.fail : LensTheme.faint).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 0)
                            if let event, event.total > 0 { Text("\(event.completed)/\(event.total)").font(LensTheme.caption).monospacedDigit().foregroundStyle(LensTheme.faint) }
                        }.accessibilityElement(children: .combine).accessibilityLabel("\(stage.1), \(event?.state ?? "pending"). \(event?.detail ?? "")")
                    }
                    if retryEnabled { Button(action: retry) { Label("Retry saved submission", systemImage: "arrow.clockwise") }.buttonStyle(LensButtonStyle()) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }.lensTile()
    }
}

struct FilingStatusIcon: View {
    let state: String
    var fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    var body: some View {
        ZStack {
            if state == "completed" { Image(systemName: "checkmark.circle").foregroundStyle(LensTheme.ok) }
            else if state == "failed" { Image(systemName: "xmark.circle").foregroundStyle(LensTheme.fail) }
            else if state == "active" {
                Circle().stroke(LensTheme.lineStrong, lineWidth: 1.5)
                Circle().trim(from: 0, to: min(1, max(0, fraction ?? 0.68))).stroke(LensTheme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90 + (rotating && fraction == nil && !reduceMotion ? 360 : 0)))
                    .animation(fraction == nil && !reduceMotion ? .linear(duration: 1.1).repeatForever(autoreverses: false) : nil, value: rotating)
                    .onAppear { rotating = true }
            } else { Circle().stroke(LensTheme.faint, style: StrokeStyle(lineWidth: 1, dash: [2, 3])) }
        }.font(.system(size: 17)).accessibilityHidden(true)
    }
}
