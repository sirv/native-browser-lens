import SwiftUI
import AppKit
import LensCore

struct LensSettingsView: View {
    @ObservedObject var model: LensAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [ProjectProfile] = []
    @State private var selected = ""
    @State private var section = "Projects"
    @State private var openAIKey = ""
    @State private var vibeqKey = ""
    @State private var investigationModel = ""
    @State private var transcriptionModel = ""
    @State private var vibeqURL = ""
    @State private var saved = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) { Eyebrow("Lens / Settings"); Text("A workspace with context.").font(LensTheme.head) }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(LensButtonStyle())
            }.padding(24)
            Divider().overlay(LensTheme.line)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["Projects", "AI", "VibeQ", "Appearance"], id: \.self) { item in
                        Button { section = item } label: { Text(item).font(LensTheme.body).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(section == item ? LensTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(14).frame(width: 155).background(LensTheme.surface)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if section == "Projects" { projectSettings }
                        else if section == "AI" { aiSettings }
                        else if section == "VibeQ" { vibeqSettings }
                        else { appearanceSettings }
                        if !saved.isEmpty { Text(saved).font(LensTheme.detail).foregroundStyle(LensTheme.soft) }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(width: 800, height: 690).foregroundStyle(LensTheme.ink).background(LensTheme.background).tint(LensTheme.accent)
            .preferredColorScheme(model.appearance == "system" ? nil : (model.appearance == "light" ? .light : .dark))
            .onAppear {
                projects = model.projects; selected = projects.first?.id ?? ""
                openAIKey = (try? KeychainStore.get(key: "openai")) ?? ""
                vibeqKey = (try? KeychainStore.get(key: "vibeq")) ?? ""
                investigationModel = model.investigationModel; transcriptionModel = model.transcriptionModel; vibeqURL = model.vibeqURL
            }
    }
    private var projectSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Projects").font(LensTheme.head)
            Text("Lens collects only exact origins you enable here and grant in Chrome. A project keeps its source, documentation, and ownership together.").font(LensTheme.body).foregroundStyle(LensTheme.soft)
            HStack {
                Picker("Project", selection: $selected) { ForEach(projects) { Text($0.name).tag($0.id) } }.labelsHidden()
                Menu("Add project") {
                    Button("Blank project") { add(ProjectProfile()) }
                    Button("Sirv Studio") { add(ProjectProfile(name: "Sirv Studio", origins: ["https://dev.sirv.studio", "http://localhost:3000"], repositoryPath: "/Users/veniaminkrachun/git/sirv-studio", adapter: "sirv")) }
                    Button("VibeQ") { add(ProjectProfile(name: "VibeQ", origins: ["http://localhost:5173"], repositoryPath: "/Users/veniaminkrachun/git/vibequeue")) }
                }.fixedSize()
            }
            if let index = projects.firstIndex(where: { $0.id == selected }) {
                field("Project name", text: $projects[index].name)
                Toggle("Enable background collection for this project", isOn: $projects[index].enabled).font(LensTheme.body)
                multiline("Exact origins · one per line", values: $projects[index].origins, height: 64)
                HStack(alignment: .bottom) {
                    field("Repository folder", text: $projects[index].repositoryPath)
                    Button("Choose…") { chooseRepository(index) }.buttonStyle(LensButtonStyle())
                }
                HStack {
                    Picker("Adapter", selection: $projects[index].adapter) { Text("Generic").tag("generic"); Text("Sirv Studio").tag("sirv") }
                    Picker("History", selection: $projects[index].recording) { Text("Diagnostics only").tag("diagnostics"); Text("Diagnostics + 30s video").tag("video") }
                }.font(LensTheme.meta)
                multiline("Documentation folders · relative to repository", values: $projects[index].documentationPaths, height: 54)
                multiline("Optional local server log paths", values: $projects[index].logPaths, height: 54)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Eyebrow("Ownership mappings"); Spacer(); Button { projects[index].ownership.append(OwnerRule()) } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add owner mapping") }
                    Text("Map source globs to actual VibeQ member IDs. Suggestions are verified against the member list before filing.").font(LensTheme.detail).foregroundStyle(LensTheme.soft)
                    ForEach(projects[index].ownership.indices, id: \.self) { rule in
                        HStack(spacing: 8) {
                            TextField("src/assets/**", text: $projects[index].ownership[rule].pattern)
                            TextField("Member ID", text: $projects[index].ownership[rule].memberId)
                            TextField("Name", text: $projects[index].ownership[rule].label)
                            Button { projects[index].ownership.remove(at: rule) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove mapping")
                        }.textFieldStyle(.roundedBorder).font(LensTheme.caption)
                    }
                }
                Button("Save projects") { model.saveProjects(projects); saved = model.errorMessage == nil ? "Saved. Open the extension options in Chrome and grant these exact origins." : "The projects could not be saved." }.buttonStyle(LensButtonStyle(prominent: true))
            } else {
                Button("Add Sirv Studio") { add(ProjectProfile(name: "Sirv Studio", origins: ["https://dev.sirv.studio", "http://localhost:3000"], repositoryPath: "/Users/veniaminkrachun/git/sirv-studio", adapter: "sirv")) }.buttonStyle(LensButtonStyle(prominent: true))
            }
        }
    }
    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Voice & investigation").font(LensTheme.head)
            Text("Capture and Markdown work locally. Dictation sends deliberate microphone input to OpenAI. Cloud investigation sends only the evidence selected in its review.").font(LensTheme.body).foregroundStyle(LensTheme.soft)
            VStack(alignment: .leading, spacing: 8) { Eyebrow("OpenAI API key"); SecureField("Stored in macOS Keychain", text: $openAIKey).textFieldStyle(.roundedBorder) }
            field("Transcription model", text: $transcriptionModel)
            field("Investigation model", text: $investigationModel)
            Button("Save AI settings") {
                do {
                    try KeychainStore.set(key: "openai", value: openAIKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    UserDefaults.standard.set(investigationModel, forKey: "lens.investigationModel")
                    UserDefaults.standard.set(transcriptionModel, forKey: "lens.transcriptionModel")
                    saved = "API key saved in Keychain. Model settings saved locally."
                } catch { saved = error.localizedDescription }
            }.buttonStyle(LensButtonStyle(prominent: true))
        }
    }
    private var vibeqSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("VibeQ delivery").font(LensTheme.head)
            Text("File only after reviewing the report, owner, and attachments. A saved submission identity lets Lens recover an uncertain result without creating a duplicate.").font(LensTheme.body).foregroundStyle(LensTheme.soft)
            field("VibeQ endpoint", text: $vibeqURL)
            VStack(alignment: .leading, spacing: 8) { Eyebrow("Personal API token"); SecureField("Stored in macOS Keychain", text: $vibeqKey).textFieldStyle(.roundedBorder) }
            Text("Use HTTPS for a hosted instance. Local development may use http://localhost or http://127.0.0.1.").font(LensTheme.detail).foregroundStyle(LensTheme.faint)
            Button("Save VibeQ settings") {
                do {
                    guard let url = URL(string: vibeqURL), url.host != nil, ["http", "https"].contains(url.scheme ?? "") else { throw LensError.invalid("Enter a valid VibeQ endpoint.") }
                    try KeychainStore.set(key: "vibeq", value: vibeqKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    UserDefaults.standard.set(vibeqURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "lens.vibeqURL")
                    saved = "VibeQ settings saved."
                } catch { saved = error.localizedDescription }
            }.buttonStyle(LensButtonStyle(prominent: true))
        }
    }
    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Appearance").font(LensTheme.head)
            Picker("Theme", selection: $model.appearance) { Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system") }.pickerStyle(.segmented)
            Text("The VibeQ palette: cool neutrals, indigo focus, quiet evidence.").font(LensTheme.body).foregroundStyle(LensTheme.soft)
            Text("Capture shortcut").font(LensTheme.head)
            HStack { Text("⌘ ⌥ ⇧ L").font(.system(size: 18, design: .monospaced)); Spacer(); Text("Works while Chrome is focused").font(LensTheme.detail).foregroundStyle(LensTheme.faint) }
        }
    }
    private func add(_ project: ProjectProfile) { projects.append(project); selected = project.id }
    private func chooseRepository(_ index: Int) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Choose repository"
        if panel.runModal() == .OK, let path = panel.url?.path { projects[index].repositoryPath = path }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) { Eyebrow(label); TextField(label, text: text).textFieldStyle(.roundedBorder).font(LensTheme.body) }
    }
    private func multiline(_ label: String, values: Binding<[String]>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(label)
            TextEditor(text: Binding(get: { values.wrappedValue.joined(separator: "\n") }, set: { values.wrappedValue = $0.components(separatedBy: .newlines) }))
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).frame(height: height).background(LensTheme.inset, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
