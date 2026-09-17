import Foundation
import CoreGraphics

// MARK: - Interactive tools
//
// Compositor's brush, eraser, smudge, liquify, clone stamp, spot healing, selection,
// crop, filters and merge all live on `EditorSession` as plain methods. In the app
// they are driven by AppKit mouse events; here they are driven by a synthesised path
// of points instead. Every handler follows the same shape as the document handlers:
// load the draft, run the edit, write the result back through the validating store.
//
// Two things differ from the original build request, both forced by Compositor's own
// source (confirmed by reading it, see README):
//   * Points are in CANVAS/document pixels, not layer-local. `BrushStroke` maps canvas
//     points onto the layer through the layer transform itself, so a canvas point is
//     what every entry point actually takes.
//   * `path` points accept an optional `pressure`, but Compositor's `BrushSettings` has
//     no per-point pressure input, so it is recorded and ignored rather than faked.

/// Loads a document into a headless `EditorSession`, runs `body`, and writes the result
/// back. The session is rebuilt per call (matching the existing snapshot-per-call model);
/// the one piece of session state that must outlive a call — the selection — is persisted
/// on the open document and re-injected here.
private func withSession(_ handle: String, _ store: DocumentStore,
                         _ body: (EditorSession) async throws -> Void) async throws {
    let document = try await store.get(handle)
    let session = EditorSession()
    session.installProject(document.snapshot, from: document.url ?? URL(fileURLWithPath: "/tmp/\(handle).comp"))
    session.document?.selection = document.selection
    try await body(session)
    if let brushError = session.brushError { throw RPCError.internalError(brushError) }
    if let cropError = session.cropError { throw RPCError.internalError(cropError) }
    guard let result = session.projectSnapshot() else {
        throw RPCError.internalError("The edit left the document empty.")
    }
    try await store.update(handle, to: result)
    try await store.setSelection(handle, session.document?.selection)
}

/// A stroke point in canvas pixels, with the pressure Compositor cannot yet use.
private struct StrokePoint { let point: CGPoint; let pressure: Double }

private func strokePath(_ p: Params, _ key: String) throws -> [StrokePoint] {
    guard let raw = p.raw[key] as? [[String: Any]], !raw.isEmpty else {
        throw RPCError.invalidParams("`\(key)` must be a non-empty array of {x, y, pressure?} points.")
    }
    return try raw.map { entry in
        guard let x = (entry["x"] as? NSNumber)?.doubleValue, let y = (entry["y"] as? NSNumber)?.doubleValue else {
            throw RPCError.invalidParams("Each `\(key)` point needs numeric `x` and `y`.")
        }
        return StrokePoint(point: CGPoint(x: x, y: y), pressure: (entry["pressure"] as? NSNumber)?.doubleValue ?? 1)
    }
}

/// Fills in the brush tip from the shared parameters. Color and healing are set by the
/// individual entry points (beginBrush derives erasing/healing from the tool), so this
/// only covers the geometry every brush tool shares.
private func brushSettings(_ p: Params, into session: EditorSession) throws {
    var settings = session.brushSettings
    if let diameter = p.double("diameter", default: nil) {
        guard (1...2000).contains(diameter) else { throw RPCError.invalidParams("`diameter` must be 1–2000.") }
        settings.diameter = CGFloat(diameter)
    }
    if let hardness = p.double("hardness", default: nil) {
        guard (0...1).contains(hardness) else { throw RPCError.invalidParams("`hardness` must be 0–1.") }
        settings.hardness = CGFloat(hardness)
    }
    if let opacity = p.double("opacity", default: nil) {
        guard (0.01...1).contains(opacity) else { throw RPCError.invalidParams("`opacity` must be 0.01–1.") }
        settings.opacity = CGFloat(opacity)
    }
    settings.red = CGFloat(p.double("red", default: Double(settings.red))!)
    settings.green = CGFloat(p.double("green", default: Double(settings.green))!)
    settings.blue = CGFloat(p.double("blue", default: Double(settings.blue))!)
    session.brushSettings = settings
}

private func targetLayer(_ p: Params) throws -> UUID {
    let id = try p.string("layer")
    guard let uuid = UUID(uuidString: id) else {
        throw RPCError.invalidParams("`\(id)` is not a layer id. Use describe_document to list them.")
    }
    return uuid
}

/// Runs one begin → continue×N → finish gesture. `beginBrush`/`continueBrush`/
/// `finishBrushImmediately` route brush, eraser, spot healing, clone stamp and blur, and
/// dispatch smudge/liquify to the warp stroke internally, so every brush-family tool uses
/// this same sequence.
private func runStroke(_ session: EditorSession, _ path: [StrokePoint]) {
    session.beginBrush(at: path[0].point)
    for step in path.dropFirst() { session.continueBrush(at: step.point) }
    session.finishBrushImmediately()
}

// MARK: - paint_stroke (brush / eraser / smudge / liquify)

func paintStroke(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let layer = try targetLayer(p)
    let path = try strokePath(p, "path")
    let toolName = p.string("tool", default: "brush")!
    try await withSession(handle, store) { session in
        session.activeLayerID = layer
        try brushSettings(p, into: session)
        switch toolName {
        case "brush":   session.tool = .brush; session.brushMode = .paint
        case "eraser":  session.tool = .brush; session.brushMode = .erase
        case "smudge":  session.tool = .blur;  session.blurMode = .smudge
        case "liquify": session.tool = .blur;  session.blurMode = .liquify
        default: throw RPCError.invalidParams("`tool` must be brush, eraser, smudge or liquify.")
        }
        runStroke(session, path)
    }
    return ToolResult("Painted a \(toolName) stroke of \(path.count) points on layer \(layer.uuidString).")
}

// MARK: - clone_stamp_stroke

func cloneStampStroke(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let layer = try targetLayer(p)
    let path = try strokePath(p, "path")
    guard let source = p.object("source_point"),
          let sx = (source["x"] as? NSNumber)?.doubleValue, let sy = (source["y"] as? NSNumber)?.doubleValue else {
        throw RPCError.invalidParams("`source_point` must be {x, y}: where the clone copies from.")
    }
    try await withSession(handle, store) { session in
        session.activeLayerID = layer
        try brushSettings(p, into: session)
        session.tool = .cloneStamp
        session.setCloneSource(CGPoint(x: sx, y: sy))
        runStroke(session, path)
    }
    return ToolResult("Cloned from \(sx.clean),\(sy.clean) along \(path.count) points on layer \(layer.uuidString).")
}

// MARK: - heal_stroke (spot healing)

func healStroke(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let layer = try targetLayer(p)
    let path = try strokePath(p, "path")
    let modeName = p.string("mode", default: SpotHealingMode.contentAware.rawValue)!
    guard let mode = SpotHealingMode(rawValue: modeName) else {
        throw RPCError.invalidParams("`mode` must be one of: "
            + SpotHealingMode.allCases.map(\.rawValue).joined(separator: ", ") + ".")
    }
    try await withSession(handle, store) { session in
        session.activeLayerID = layer
        try brushSettings(p, into: session)
        session.tool = .spotHealing
        session.spotHealingMode = mode
        runStroke(session, path)
    }
    return ToolResult("Healed \(path.count) points on layer \(layer.uuidString) (\(mode.rawValue)).")
}

