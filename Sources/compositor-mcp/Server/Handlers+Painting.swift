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

// MARK: - apply_selection

func applySelection(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let shape = p.string("shape", default: "rect")!
    let modeName = p.string("mode", default: SelectionMode.replace.rawValue)!
    // Compositor's SelectionMode is New/Add/Subtract; accept the lower-case aliases too.
    let mode: SelectionMode
    switch modeName.lowercased() {
    case "replace", "new": mode = .replace
    case "add":            mode = .add
    case "subtract":       mode = .subtract
    default: throw RPCError.invalidParams("`mode` must be replace, add or subtract (Compositor has no intersect).")
    }
    let path = CGMutablePath()
    switch shape {
    case "rect", "ellipse":
        guard let x = p.double("x", default: nil), let y = p.double("y", default: nil),
              let w = p.double("width", default: nil), let h = p.double("height", default: nil) else {
            throw RPCError.invalidParams("A \(shape) needs `x`, `y`, `width` and `height`.")
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        if shape == "rect" { path.addRect(rect) } else { path.addEllipse(in: rect) }
    case "lasso":
        guard let points = p.raw["points"] as? [[String: Any]], points.count >= 3 else {
            throw RPCError.invalidParams("A lasso needs `points`: at least 3 {x, y} vertices.")
        }
        let vertices = try points.map { entry -> CGPoint in
            guard let x = (entry["x"] as? NSNumber)?.doubleValue, let y = (entry["y"] as? NSNumber)?.doubleValue else {
                throw RPCError.invalidParams("Each lasso point needs numeric `x` and `y`.")
            }
            return CGPoint(x: x, y: y)
        }
        path.addLines(between: vertices)
        path.closeSubpath()
    default:
        throw RPCError.invalidParams("`shape` must be rect, ellipse or lasso.")
    }
    try await withSession(handle, store) { session in
        session.applySelection(path, mode: mode, name: "Select")
    }
    // `feather` is accepted for forward-compatibility but ignored: Compositor's selection
    // stores no feather radius (edges are antialiased only). Noted in the README.
    return ToolResult("Applied \(shape) selection (\(mode.rawValue)) to document \(handle).")
}

// MARK: - crop_canvas

func cropCanvas(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    try await withSession(handle, store) { session in
        guard let document = session.document else { throw RPCError.invalidParams("No canvas to crop.") }
        let rect: CGRect
        if p.bool("use_selection", default: false)! {
            guard let box = session.document?.selection?.path.boundingBoxOfPath, !box.isNull, !box.isEmpty else {
                throw RPCError.invalidParams("No selection to crop to. Call apply_selection first or pass a rect.")
            }
            rect = box.integral
        } else {
            guard let x = p.double("x", default: nil), let y = p.double("y", default: nil),
                  let w = p.double("width", default: nil), let h = p.double("height", default: nil) else {
                throw RPCError.invalidParams("Pass a crop rect (`x`, `y`, `width`, `height`) or `use_selection`: true.")
            }
            rect = CGRect(x: x, y: y, width: w, height: h)
        }
        guard rect.intersection(CGRect(origin: .zero, size: document.size)).isEmpty == false else {
            throw RPCError.invalidParams("The crop rect is outside the canvas.")
        }
        session.cropRect = rect
        await session.commitCrop()
    }
    return ToolResult("Cropped document \(handle).")
}

// MARK: - apply_filter

func applyFilter(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let layer = try targetLayer(p)
    let name = try p.string("filter")
    // Map the request's snake_case names onto Compositor's FilterKind raw values.
    let kinds: [String: FilterKind] = [
        "gaussian_blur": .gaussianBlur, "motion_blur": .motionBlur,
        "add_noise": .addNoise, "lens_correction": .lensCorrection,
    ]
    guard let kind = kinds[name] else {
        throw RPCError.invalidParams("`filter` must be one of: \(kinds.keys.sorted().joined(separator: ", ")).")
    }
    try await withSession(handle, store) { session in
        session.activeLayerID = layer
        var settings = session.filterSettings
        if let radius = p.double("radius", default: nil) { settings.radius = radius }
        if let angle = p.double("angle", default: nil) { settings.angle = angle }
        if let distance = p.double("distance", default: nil) { settings.distance = distance }
        if let amount = p.double("amount", default: nil) { settings.amount = amount }
        if let gaussian = p.bool("gaussian", default: nil) { settings.gaussian = gaussian }
        if let mono = p.bool("monochromatic", default: nil) { settings.monochromatic = mono }
        if let distortion = p.double("distortion", default: nil) { settings.distortion = distortion }
        session.beginFilter(kind)
        guard session.filterEdit != nil else {
            throw RPCError.internalError("Compositor refused the filter: the layer may have no pixels.")
        }
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
    }
    return ToolResult("Applied \(name) to layer \(layer.uuidString).")
}

