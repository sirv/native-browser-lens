import Foundation

public extension EvidenceStore {
    func importObservation(from folder: URL, projectId: String) throws -> NotebookObservation {
        let manifest = folder.appendingPathComponent("evidence.json")
        guard (try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw LensError.invalid("The portable report exceeds the import limit") }
        let original = try JSONDecoder().decode(NotebookObservation.self, from: Data(contentsOf: manifest))
        guard original.captures.count <= 256, original.captures.allSatisfy({ capture in
            UUID(uuidString: capture.id) != nil && capture.identity.projectId == original.projectId && capture.events.allSatisfy { $0.projectId == original.projectId && $0.tabId == capture.identity.tabId && $0.documentId == capture.identity.documentId }
        }) else { throw LensError.invalid("The portable report has inconsistent capture identities") }
        func media(_ name: String, suffix: String) throws -> URL {
            let file = folder.appendingPathComponent(name)
            guard !name.isEmpty, name == file.lastPathComponent, !name.contains(".."), !name.contains("\\"), file.pathExtension == suffix,
                  file.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath(),
                  (try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])).isSymbolicLink != true,
                  (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 64 * 1024 * 1024 else { throw LensError.invalid("Portable media must be a regular file inside the selected report") }
            return file
        }
        for capture in original.captures {
            for record in DiagnosticArtifacts.records(capture) {
                if let name = record["path"]?.stringValue { guard ["json", "zip"].contains(URL(fileURLWithPath: name).pathExtension) else { throw LensError.invalid("Unknown diagnostic artifact format") }; _ = try media(name, suffix: URL(fileURLWithPath: name).pathExtension) }
            }
            if let name = capture.screenshotPath { _ = try media(name, suffix: "png") }
            if let name = capture.context["videoPath"]?.stringValue { _ = try media(name, suffix: "mp4") }
        }
        var item = original
        item.id = UUID().uuidString; item.projectId = projectId; item.receipt = nil
        item.archivedAt = nil; item.trashedAt = nil; item.draftRevision = 1; item.editVersion = 0
        do {
            for i in item.captures.indices {
                let originalID = item.captures[i].id
                item.captures[i].id = UUID().uuidString
                let importedID = item.captures[i].id
                if item.captures[i].context["captureId"]?.stringValue == originalID { item.captures[i].context["captureId"] = .string(importedID) }
                for key in ["elements", "annotationBindings"] {
                    if let bindings = item.captures[i].context[key]?.arrayValue {
                        item.captures[i].context[key] = .array(bindings.map { binding in
                            guard var fields = binding.objectValue, fields["captureId"]?.stringValue == originalID else { return binding }
                            fields["captureId"] = .string(importedID); return .object(fields)
                        })
                    }
                }
                item.captures[i].identity.projectId = projectId
                for j in item.captures[i].events.indices { item.captures[i].events[j].projectId = projectId }
                item.captures[i].originalScreenshotPath = nil
                item.captures[i].gaps.append(CoverageGap(channel: "import", reason: "Portable evidence imported under a new notebook/capture identity. Source bindings refer to the original recorded document; evidence was not recollected."))
                var diagnostics: [JSONValue] = []
                for record in DiagnosticArtifacts.records(original.captures[i]) {
                    guard var fields = record.objectValue else { continue }
                    fields["id"] = .string(UUID().uuidString); fields["reviewed"] = .bool(false)
                    if let name = record["path"]?.stringValue {
                        let bytes = try Data(contentsOf: media(name, suffix: URL(fileURLWithPath: name).pathExtension))
                        guard sha256(bytes) == record["sha256"]?.stringValue else { throw LensError.invalid("Imported diagnostic checksum mismatch") }
                        fields["path"] = .string(try saveArtifact(observationId: item.id, filename: "diagnostic-" + UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension, data: bytes).path)
                    }
                    diagnostics.append(.object(fields))
                }
                if !diagnostics.isEmpty { item.captures[i].context["diagnosticArtifacts"] = .array(diagnostics) }
                if let name = original.captures[i].screenshotPath {
                    let bytes = try Data(contentsOf: media(name, suffix: "png"))
                    guard bytes.starts(with: [137,80,78,71,13,10,26,10]) else { throw LensError.invalid("Imported screenshot is not PNG") }
                    let url = try saveArtifact(observationId: item.id, filename: item.captures[i].id + "-imported.png", data: bytes)
                    item.captures[i].screenshotPath = url.path; item.captures[i].originalScreenshotPath = url.path
                }
                if !item.captures[i].annotations.isEmpty {
                    item.captures[i].context["importedAnnotations"] = try .from(item.captures[i].annotations)
                    item.captures[i].annotations = []
                    item.captures[i].gaps.append(CoverageGap(channel: "import", reason: "Imported marks are baked into the portable image; the private original and editable annotation layers are unavailable."))
                }
                if let name = original.captures[i].context["videoPath"]?.stringValue {
                    let bytes = try Data(contentsOf: media(name, suffix: "mp4"))
                    guard bytes.dropFirst(4).prefix(4) == Data("ftyp".utf8) else { throw LensError.invalid("Imported recording is not MP4") }
                    let url = try saveArtifact(observationId: item.id, filename: item.captures[i].id + "-imported.mp4", data: bytes)
                    item.captures[i].context["videoPath"] = .string(url.path)
                    item.captures[i].context["videoReviewed"] = .bool(false)
                }
            }
            try save(item)
            return item
        } catch {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("observations/" + item.id))
            throw error
        }
    }
}
