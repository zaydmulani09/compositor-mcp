import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tool dispatch
//
// Every handler works on a `ProjectSnapshot`: the same value Compositor's own
// renderer and project store consume. Edits go through the store, which
// validates the layer tree before accepting them.

func callTool(_ name: String, _ params: Params, _ store: DocumentStore) async throws -> ToolResult {
    switch name {
    case "create_document":    return try await createDocument(params, store)
    case "open_document":      return try await openDocument(params, store)
    case "save_document":      return try await saveDocument(params, store)
    case "close_document":     return try await closeDocument(params, store)
    case "list_documents":     return await listDocuments(store)
    case "describe_document":  return try await describeDocument(params, store)
    case "import_image":       return try await importImage(params, store)
    case "set_layer":          return try await setLayer(params, store)
    case "transform_layer":    return try await transformLayer(params, store)
    case "reorder_layer":      return try await reorderLayer(params, store)
    case "delete_layer":       return try await deleteLayer(params, store)
    case "duplicate_layer":    return try await duplicateLayer(params, store)
    case "group_layers":       return try await groupLayers(params, store)
    case "add_adjustment_layer": return try await addAdjustmentLayer(params, store)
    case "describe_adjustment":  return try describeAdjustment(params)
    case "set_clipping_mask":  return try await setClippingMask(params, store)
    // Interactive tools (pixel painting)
    case "paint_stroke":       return try await paintStroke(params, store)
    case "clone_stamp_stroke": return try await cloneStampStroke(params, store)
    case "heal_stroke":        return try await healStroke(params, store)
    case "apply_selection":    return try await applySelection(params, store)
    case "crop_canvas":        return try await cropCanvas(params, store)
    case "apply_filter":       return try await applyFilter(params, store)
    case "merge_layers":       return try await mergeLayers(params, store)
    case "flatten_document":   return try await flattenDocument(params, store)
    case "resize_canvas":      return try await resizeCanvas(params, store)
    case "resize_image":       return try await resizeImage(params, store)
    case "render_preview":     return try await renderPreview(params, store)
    case "export_image":       return try await exportImage(params, store)
    // ContentMaschine
    case "generate_layer":          return try await generateLayer(params, store)
    case "vary_layer":              return try await varyLayer(params, store)
    case "fuse_layers":             return try await fuseLayers(params, store)
    case "remove_layer_background": return try await removeLayerBackground(params, store)
    case "upscale_layer":           return try await upscaleLayer(params, store)
    case "restyle_composition":     return try await restyleComposition(params, store)
    case "list_generations":        return try await listGenerations(params)
    case "import_generation":       return try await importGeneration(params, store)
    default: throw RPCError.methodNotFound("No tool named `\(name)`.")
    }
}

// MARK: - Documents

private func createDocument(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let width = try p.int("width"), height = try p.int("height")
    guard (1...30_000).contains(width), (1...30_000).contains(height) else {
        throw RPCError.invalidParams("Canvas sides must be between 1 and 30000 pixels.")
    }
    guard width * height <= 100_000_000 else {
        throw RPCError.invalidParams("A canvas may hold at most 100 megapixels.")
    }
    let resolution = p.double("resolution", default: 72)!
    let name = p.string("name", default: "Untitled")!
    let manifest = ProjectManifest(resolution: resolution, documentID: UUID(), width: width, height: height,
                                   activeLayerID: nil, layers: [])
    let handle = await store.insert(ProjectSnapshot(manifest: manifest, images: [:]), url: nil, name: name)
    return ToolResult("Created \(name): \(width)x\(height) at \(Int(resolution)) ppi.\nDocument handle: \(handle)")
}

private func openDocument(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let url = try p.path("path")
    let snapshot = try await ProjectStore.shared.load(from: url)
    let name = url.deletingPathExtension().lastPathComponent
    let handle = await store.insert(snapshot, url: url, name: name)
    return ToolResult("""
        Opened \(name): \(snapshot.manifest.width)x\(snapshot.manifest.height), \
        \(snapshot.manifest.layers.count) layers, format version \(snapshot.manifest.version).
        Document handle: \(handle)
        """)
}

private func saveDocument(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let document = try await store.get(handle)
    guard let url = p.path("path", orNil: true) ?? document.url else {
        throw RPCError.invalidParams("This document has never been saved. Pass `path`.")
    }
    let target = url.pathExtension.lowercased() == "comp" ? url : url.appendingPathExtension("comp")
    try await ProjectStore.shared.save(document.snapshot, to: target)
    try await store.markSaved(handle, url: target)
    return ToolResult("Saved to \(target.path)")
}

private func closeDocument(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let document = try await store.remove(handle)
    let warning = document.isModified ? " Unsaved changes were discarded." : ""
    return ToolResult("Closed \(document.name).\(warning)")
}

private func listDocuments(_ store: DocumentStore) async -> ToolResult {
    let all = await store.all()
    guard !all.isEmpty else { return ToolResult("No documents are open. Use create_document or open_document.") }
    let rows = all.map { handle, document in
        let state = document.isModified ? "unsaved changes" : "saved"
        let where_ = document.url?.path ?? "never saved"
        return "\(handle)  \(document.name)  \(document.snapshot.manifest.width)x"
             + "\(document.snapshot.manifest.height)  \(document.snapshot.manifest.layers.count) layers  "
             + "[\(state)]  \(where_)"
    }
    return ToolResult(rows.joined(separator: "\n"))
}

private func describeDocument(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let document = try await store.get(handle)
    let snapshot = document.snapshot
    let manifest = snapshot.manifest

    // Top first, the order the Layers panel shows.
    let entries = LayerHierarchy.entries(manifest.layers, topFirst: true)
    var lines: [String] = []
    for entry in entries {
        let l = entry.layer
        let indent = String(repeating: "  ", count: entry.depth)
        var parts = ["\(l.transform.origin.x.clean),\(l.transform.origin.y.clean)"
                     + " \(l.transform.size.width.clean)x\(l.transform.size.height.clean)"]
        if l.transform.rotation != 0 { parts.append("rot \(l.transform.rotation.clean)deg") }
        if l.transform.flipX { parts.append("flipped H") }
        if l.transform.flipY { parts.append("flipped V") }
        if let o = l.opacity, o != 1 { parts.append("opacity \(Int((o * 100).rounded()))%") }
        if let b = l.blendMode, b != .normal { parts.append(b.rawValue) }
        if l.maskFile != nil { parts.append(l.maskEnabled == false ? "mask (off)" : "mask") }
        if l.maskSourceID != nil { parts.append("clipped") }
        if !l.isVisible { parts.append("hidden") }
        lines.append("\(indent)\(l.name)  [\(l.kindLabel)]  \(parts.joined(separator: ", "))")
        lines.append("\(indent)  id: \(l.id.uuidString)")
    }
    let tree = lines.isEmpty ? "  (no layers)" : lines.joined(separator: "\n")
    return ToolResult("""
        \(document.name) — \(manifest.width)x\(manifest.height) at \(Int(manifest.resolution ?? 72)) ppi, \
        \(manifest.layers.count) layers\(document.isModified ? " (unsaved changes)" : "")

        Layers, top first:
        \(tree)
        """)
}

// MARK: - Layers

private func importImage(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let url = try p.path("path")

    let used = snapshot.images.values.reduce(0) { $0 + $1.image.width * $1.image.height }
    let imported = try await ImageImporter.shared.decode(url, remainingPixels: max(0, 100_000_000 - used))

    let pixels = CGSize(width: imported.image.width, height: imported.image.height)
    var size = pixels
    if p.bool("fit", default: false)! {
        let scale = min(Double(snapshot.manifest.width) / pixels.width,
                        Double(snapshot.manifest.height) / pixels.height, 1)
        size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    } else if let percent = p.double("scale_percent", default: nil) {
        guard percent > 0 else { throw RPCError.invalidParams("`scale_percent` must be greater than 0.") }
        size = CGSize(width: (pixels.width * percent / 100).rounded(),
                      height: (pixels.height * percent / 100).rounded())
    }
    let origin = CGPoint(
        x: p.double("x", default: (Double(snapshot.manifest.width) - Double(size.width)) / 2)!,
        y: p.double("y", default: (Double(snapshot.manifest.height) - Double(size.height)) / 2)!)

    let id = UUID()
    var record = ProjectLayerRecord(
        id: id, name: p.string("name", default: imported.name)!, isVisible: true,
        transform: LayerTransform(origin: origin, size: size),
        imageFile: "\(id.uuidString).png")
    record.opacity = p.double("opacity", default: nil)
    record.blendMode = try blendMode(p)
    guard record.transform.isValid else { throw RPCError.invalidParams("That position or size is out of range.") }

    snapshot.manifest.layers.append(record)
    snapshot.images[id] = imported
    try await store.update(handle, to: snapshot.snapshot)
    return ToolResult("""
        Imported \(imported.name) (\(imported.image.width)x\(imported.image.height) pixels) as layer \
        "\(record.name)", drawn at \(origin.x.clean),\(origin.y.clean) sized \
        \(size.width.clean)x\(size.height.clean).
        Layer id: \(id.uuidString)
        """)
}

private func blendMode(_ p: Params) throws -> LayerBlendMode? {
    guard let raw = p.string("blend_mode", default: nil) else { return nil }
    guard let mode = LayerBlendMode(rawValue: raw) else {
        throw RPCError.invalidParams("`\(raw)` is not a blend mode. Use one of: \(blendModes.joined(separator: ", ")).")
    }
    return mode
}

private func setLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let index = try snapshot.layerIndex(try p.string("layer"))
    var record = snapshot.manifest.layers[index]
    var changes: [String] = []

    if let name = p.string("name", default: nil) {
        record = record.renamed(name)
        changes.append("name -> \(name)")
    }
    if let visible = p.bool("visible", default: nil) {
        record.isVisible = visible
        changes.append(visible ? "shown" : "hidden")
    }
    if let opacity = p.double("opacity", default: nil) {
        guard (0...1).contains(opacity) else { throw RPCError.invalidParams("`opacity` must be between 0 and 1.") }
        record.opacity = opacity
        changes.append("opacity -> \(Int((opacity * 100).rounded()))%")
    }
    if let mode = try blendMode(p) {
        record.blendMode = mode
        changes.append("blend -> \(mode.rawValue)")
    }
    guard !changes.isEmpty else {
        throw RPCError.invalidParams("Nothing to change. Pass name, visible, opacity or blend_mode.")
    }
    snapshot.manifest.layers[index] = record
    try await store.update(handle, to: snapshot.snapshot)
    return ToolResult("Updated \"\(record.name)\": \(changes.joined(separator: ", ")).")
}

private func transformLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let index = try snapshot.layerIndex(try p.string("layer"))
    var record = snapshot.manifest.layers[index]
    var transform = record.transform

    if let percent = p.double("scale_percent", default: nil) {
        let pixels = snapshot.images[record.id].map { CGSize(width: $0.image.width, height: $0.image.height) }
            ?? transform.size
        transform = transform.scaled(toPercent: percent, pixelSize: pixels)
    }
    if let width = p.double("width", default: nil) { transform.size.width = width }
    if let height = p.double("height", default: nil) { transform.size.height = height }
    if let x = p.double("x", default: nil) { transform.origin.x = x }
    if let y = p.double("y", default: nil) { transform.origin.y = y }
    if let rotation = p.double("rotation", default: nil) { transform.rotation = rotation }
    if let flip = p.bool("flip_horizontal", default: nil) { transform.flipX = flip }
    if let flip = p.bool("flip_vertical", default: nil) { transform.flipY = flip }
    if let raw = p.string("sampling", default: nil) {
        guard let sampling = LayerSampling(rawValue: raw) else {
            throw RPCError.invalidParams("`\(raw)` is not a sampling mode.")
        }
        transform.sampling = sampling
    }
    guard transform.isValid else { throw RPCError.invalidParams("That transform is out of range.") }

    record = record.withTransform(transform)
    snapshot.manifest.layers[index] = record
    try await store.update(handle, to: snapshot.snapshot)
    return ToolResult("""
        "\(record.name)" is now at \(transform.origin.x.clean),\(transform.origin.y.clean), sized \
        \(transform.size.width.clean)x\(transform.size.height.clean)\
        \(transform.rotation == 0 ? "" : ", rotated \(transform.rotation.clean) degrees").
        """)
}

private func reorderLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let id = try p.string("layer")
    var record = try snapshot.layer(id)
    let target = p.string("parent", default: nil)
    var parentID: UUID? = nil
    if let target {
        let parent = try snapshot.layer(target)
        guard parent.isGroupLayer else { throw RPCError.invalidParams("`parent` must be a folder.") }
        guard !snapshot.subtree(of: record.id).contains(parent.id) else {
            throw RPCError.invalidParams("A folder cannot be moved inside itself.")
        }
        parentID = parent.id
    }
    record.parentID = parentID

    // Children are found by parentID, so only this record moves; its contents follow.
    snapshot.manifest.layers.removeAll { $0.id == record.id }
    let siblings = snapshot.manifest.layers.enumerated().filter { $0.element.parentID == parentID }
    let index = try p.int("to_index")
    guard index >= 0, index <= siblings.count else {
        throw RPCError.invalidParams("`to_index` must be between 0 and \(siblings.count).")
    }
    let insertAt = index == siblings.count
        ? (siblings.last.map { $0.offset + 1 } ?? snapshot.manifest.layers.count)
        : siblings[index].offset
    snapshot.manifest.layers.insert(record, at: insertAt)

    try await store.update(handle, to: snapshot.snapshot)
    let place = parentID == nil ? "the top level" : "folder \"\(try snapshot.layer(target!).name)\""
    return ToolResult("Moved \"\(record.name)\" to position \(index) of \(place) (0 is the bottom).")
}

private func deleteLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let record = try snapshot.layer(try p.string("layer"))
    let doomed = snapshot.subtree(of: record.id)

    snapshot.manifest.layers.removeAll { doomed.contains($0.id) }
    // A clip pointing at a deleted layer would fail validation, so release it.
    for index in snapshot.manifest.layers.indices {
        if let source = snapshot.manifest.layers[index].maskSourceID, doomed.contains(source) {
            snapshot.manifest.layers[index].maskSourceID = nil
        }
    }
    for id in doomed { snapshot.images.removeValue(forKey: id); snapshot.masks.removeValue(forKey: id) }

    try await store.update(handle, to: snapshot.snapshot)
    let extra = doomed.count > 1 ? " and \(doomed.count - 1) layers inside it" : ""
    return ToolResult("Deleted \"\(record.name)\"\(extra).")
}

private func duplicateLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let index = try snapshot.layerIndex(try p.string("layer"))
    let original = snapshot.manifest.layers[index]
    guard !original.isGroupLayer else {
        throw RPCError.invalidParams("Folders cannot be duplicated yet. Duplicate the layers inside it.")
    }
    let id = UUID()
    let copy = original.copied(as: id, named: p.string("name", default: original.name + " copy")!)
    if let image = snapshot.images[original.id] { snapshot.images[id] = image }
    if let mask = snapshot.masks[original.id] { snapshot.masks[id] = mask }
    snapshot.manifest.layers.insert(copy, at: index + 1)
    try await store.update(handle, to: snapshot.snapshot)
    return ToolResult("Duplicated \"\(original.name)\" as \"\(copy.name)\".\nLayer id: \(id.uuidString)")
}

private func groupLayers(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let ids = try p.strings("layers")
    guard !ids.isEmpty else { throw RPCError.invalidParams("`layers` must name at least one layer.") }
    let records = try ids.map { try snapshot.layer($0) }

    let groupID = UUID()
    let group = ProjectLayerRecord(
        id: groupID, name: p.string("name", default: "Group")!, isVisible: true,
        transform: snapshot.canvasTransform, imageFile: nil,
        parentID: records[0].parentID, isGroup: true)

    let members = Set(records.map(\.id))
    guard let lowest = snapshot.manifest.layers.firstIndex(where: { members.contains($0.id) }) else {
        throw RPCError.invalidParams("Those layers are not in this document.")
    }
    for index in snapshot.manifest.layers.indices where members.contains(snapshot.manifest.layers[index].id) {
        snapshot.manifest.layers[index].parentID = groupID
    }
    snapshot.manifest.layers.insert(group, at: lowest)

    try await store.update(handle, to: snapshot.snapshot)
    return ToolResult("""
        Grouped \(records.count) layers into folder "\(group.name)".
        Folder id: \(groupID.uuidString)
        """)
}

private func setClippingMask(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let index = try snapshot.layerIndex(try p.string("layer"))
    let record = snapshot.manifest.layers[index]
    let enabled = p.bool("enabled", default: true)!

    if enabled {
        let siblings = snapshot.manifest.layers.filter { $0.parentID == record.parentID }
        guard let position = siblings.firstIndex(where: { $0.id == record.id }), position > 0 else {
            throw RPCError.invalidParams("\"\(record.name)\" has no layer below it to clip to.")
        }
        let base = siblings[position - 1]
        guard !base.isGroupLayer else { throw RPCError.invalidParams("A layer cannot be clipped to a folder.") }
        snapshot.manifest.layers[index].maskSourceID = base.id
        try await store.update(handle, to: snapshot.snapshot)
        return ToolResult("\"\(record.name)\" is now clipped to \"\(base.name)\".")
    }
    snapshot.manifest.layers[index].maskSourceID = nil
    try await store.update(handle, to: snapshot.snapshot)
    return ToolResult("Released the clipping mask on \"\(record.name)\".")
}
