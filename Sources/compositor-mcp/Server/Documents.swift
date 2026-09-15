import Foundation
import CoreGraphics

// MARK: - Open documents
//
// Editing a project one tool call at a time through files would reload and
// re-encode the whole package on every change. Instead a document is opened
// once, edited in memory as a `ProjectSnapshot` (exactly the value the app's
// own renderer and store consume) and written back when the agent asks.

/// A document held open between tool calls.
struct OpenDocument {
    var snapshot: ProjectSnapshot
    var url: URL?
    var isModified: Bool
    var name: String
    /// The active selection. `ProjectSnapshot` does not carry it (Compositor never saves
    /// it to disk), so it is held here to survive between tool calls: apply_selection sets
    /// it, paint_stroke and crop_canvas read it.
    var selection: DocumentSelection?
}

actor DocumentStore {
    private var documents: [String: OpenDocument] = [:]
    private var counter = 0

    private func nextHandle() -> String {
        counter += 1
        return "doc\(counter)"
    }

    @discardableResult
    func insert(_ snapshot: ProjectSnapshot, url: URL?, name: String) -> String {
        let handle = nextHandle()
        documents[handle] = OpenDocument(snapshot: snapshot, url: url, isModified: url == nil, name: name)
        return handle
    }

    func get(_ handle: String) throws -> OpenDocument {
        guard let document = documents[handle] else {
            let known = documents.keys.sorted().joined(separator: ", ")
            throw RPCError.invalidParams(
                "No open document `\(handle)`. Open documents: \(known.isEmpty ? "none" : known).")
        }
        return document
    }

    func snapshot(_ handle: String) throws -> ProjectSnapshot { try get(handle).snapshot }

    /// Replaces a document's contents, validating the layer tree first so a bad
    /// edit is rejected before it can be rendered or saved.
    func update(_ handle: String, to snapshot: ProjectSnapshot) throws {
        var document = try get(handle)
        try LayerHierarchy.validate(snapshot.manifest.layers)
        document.snapshot = snapshot
        document.isModified = true
        documents[handle] = document
    }

    func markSaved(_ handle: String, url: URL) throws {
        var document = try get(handle)
        document.url = url
        document.isModified = false
        document.name = url.deletingPathExtension().lastPathComponent
        documents[handle] = document
    }

    func remove(_ handle: String) throws -> OpenDocument {
        let document = try get(handle)
        documents.removeValue(forKey: handle)
        return document
    }

    func all() -> [(handle: String, document: OpenDocument)] {
        documents.keys.sorted().map { ($0, documents[$0]!) }
    }
}

// MARK: - Layer lookup and tree edits

/// `ProjectSnapshot` is immutable, which is what makes it safe to hand to the
/// renderer. A draft is the mutable working copy a tool edits, and it converts
/// back to a snapshot when the edit is complete.
struct Draft {
    var manifest: ProjectManifest
    var images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage]

    var snapshot: ProjectSnapshot { ProjectSnapshot(manifest: manifest, images: images, masks: masks) }

    func layerIndex(_ id: String) throws -> Int {
        guard let uuid = UUID(uuidString: id) else {
            throw RPCError.invalidParams("`\(id)` is not a layer id. Use describe_document to list them.")
        }
        guard let index = manifest.layers.firstIndex(where: { $0.id == uuid }) else {
            throw RPCError.invalidParams("No layer `\(id)` in this document.")
        }
        return index
    }

    func layer(_ id: String) throws -> ProjectLayerRecord { manifest.layers[try layerIndex(id)] }

    /// A group owns every layer nested beneath it. Structural edits move or
    /// delete that whole subtree so the tree stays valid.
    func subtree(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for layer in manifest.layers where layer.parentID.map({ result.contains($0) }) == true {
                if result.insert(layer.id).inserted { changed = true }
            }
        }
        return result
    }

    var canvasTransform: LayerTransform {
        LayerTransform(origin: .zero, size: CGSize(width: manifest.width, height: manifest.height))
    }
}

extension ProjectSnapshot {
    var draft: Draft { Draft(manifest: manifest, images: images, masks: masks) }
}

extension ProjectLayerRecord {
    var isGroupLayer: Bool { isGroup == true }

    var kindLabel: String {
        if isGroupLayer { return "folder" }
        if let adjustment { return "adjustment (\(adjustment.kind.rawValue))" }
        if imageFile != nil { return "image" }
        return "empty"
    }
}
