import XCTest
import CoreGraphics
@testable import compositor_mcp

// Every interactive tool is checked the same way: build a document, run the tool, render
// through Compositor's own exporter, and assert the exported PIXELS changed where the edit
// ran and stayed put elsewhere. "Didn't throw" is not enough — these read the raster back.

final class PaintingTests: XCTestCase {

    // MARK: - Fixtures

    /// A solid RGBA image, top-left origin, premultiplied — the format the renderer uses.
    private func solid(_ w: Int, _ h: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(rgba.0) / 255, green: CGFloat(rgba.1) / 255,
                         blue: CGFloat(rgba.2) / 255, alpha: CGFloat(rgba.3) / 255)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// A 100×100 document with one layer. `fill` nil leaves the layer blank (no pixels yet).
    private func makeDoc(_ store: DocumentStore, fill: (UInt8, UInt8, UInt8, UInt8)?) async -> (String, String) {
        let id = UUID()
        let record = ProjectLayerRecord(id: id, name: "Layer 1", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)),
            imageFile: fill == nil ? nil : "\(id.uuidString).png")
        var images: [UUID: ImportedImage] = [:]
        if let fill {
            let image = solid(100, 100, fill)
            images[id] = ImportedImage(image: image, thumbnail: image, name: "Layer 1")
        }
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: id, layers: [record])
        let handle = await store.insert(ProjectSnapshot(manifest: manifest, images: images), url: nil, name: "t")
        return (handle, id.uuidString)
    }

    /// The exported pixel at (x, y), top-left origin, as (r, g, b, a) 0–255.
    private func pixel(_ store: DocumentStore, _ handle: String, _ x: Int, _ y: Int) async throws
        -> (UInt8, UInt8, UInt8, UInt8) {
        let snapshot = try await store.snapshot(handle)
        let raster = try await ImageExporter.shared.render(snapshot)
        let image = raster.image
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let offset = y * ctx.bytesPerRow + x * 4
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }

    private func line(y: Int) -> [[String: Any]] {
        stride(from: 20, through: 80, by: 5).map { ["x": $0, "y": y] as [String: Any] }
    }

    // MARK: - Tools

    func testBrushPaintsColorAlongTheStroke() async throws {
        let store = DocumentStore()
        let (doc, layer) = await makeDoc(store, fill: nil)
        _ = try await paintStroke(Params(["document": doc, "layer": layer, "tool": "brush",
            "diameter": 12, "hardness": 1, "red": 1.0, "green": 0.0, "blue": 0.0, "path": line(y: 50)]), store)
        let on = try await pixel(store, doc, 50, 50)
        let off = try await pixel(store, doc, 5, 5)
        XCTAssertGreaterThan(on.3, 0, "the stroke should have painted opaque pixels")
        XCTAssertGreaterThan(on.0, on.2, "the stroke should be red, not blue")
        XCTAssertEqual(off.3, 0, "pixels away from the stroke stay transparent")
    }

    func testEraserClearsPixels() async throws {
        let store = DocumentStore()
        let (doc, layer) = await makeDoc(store, fill: (0, 0, 255, 255)) // opaque blue
        let filled = try await pixel(store, doc, 50, 50)
        XCTAssertGreaterThan(filled.3, 0)
        _ = try await paintStroke(Params(["document": doc, "layer": layer, "tool": "eraser",
            "diameter": 12, "path": line(y: 50)]), store)
        let hole = try await pixel(store, doc, 50, 50)
        let intact = try await pixel(store, doc, 5, 5)
        XCTAssertLessThan(hole.3, 128, "the eraser should have cut a hole")
        XCTAssertEqual(intact.3, 255, "pixels away from the stroke stay opaque")
    }

    func testSmudgeChangesPixelsAlongTheStroke() async throws {
        let store = DocumentStore()
        // Two halves so smudging across the seam moves colour into the other half.
        let id = UUID()
        let w = 100, h = 100
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: h))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 50, y: 0, width: 50, height: h))
        let img = ctx.makeImage()!
        let record = ProjectLayerRecord(id: id, name: "L", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: w, height: h)), imageFile: "\(id.uuidString).png")
        let manifest = ProjectManifest(documentID: UUID(), width: w, height: h, activeLayerID: id, layers: [record])
        let doc = await store.insert(ProjectSnapshot(manifest: manifest,
            images: [id: ImportedImage(image: img, thumbnail: img, name: "L")]), url: nil, name: "t")
        let before = try await pixel(store, doc, 55, 50)
        _ = try await paintStroke(Params(["document": doc, "layer": id.uuidString, "tool": "smudge",
            "diameter": 30, "path": [["x": 40, "y": 50], ["x": 60, "y": 50]]]), store)
        let after = try await pixel(store, doc, 55, 50)
        XCTAssertNotEqual(before.0, after.0, "smudging should pull red into the blue half")
    }

    func testCloneStampCopiesFromSource() async throws {
        let store = DocumentStore()
        // Left half red, right half transparent; clone the red across to the right.
        let id = UUID()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        let img = ctx.makeImage()!
        let record = ProjectLayerRecord(id: id, name: "L", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)), imageFile: "\(id.uuidString).png")
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: id, layers: [record])
        let doc = await store.insert(ProjectSnapshot(manifest: manifest,
            images: [id: ImportedImage(image: img, thumbnail: img, name: "L")]), url: nil, name: "t")
        let empty = try await pixel(store, doc, 75, 50)
        XCTAssertEqual(empty.3, 0, "the right half starts empty")
        _ = try await cloneStampStroke(Params(["document": doc, "layer": id.uuidString, "diameter": 20,
            "source_point": ["x": 25, "y": 50], "path": [["x": 75, "y": 50], ["x": 76, "y": 50]]]), store)
        let stamped = try await pixel(store, doc, 75, 50)
        XCTAssertGreaterThan(stamped.3, 0, "clone should have stamped red into the right half")
    }

    func testHealStrokeChangesTheBlemish() async throws {
        let store = DocumentStore()
        // A red field with a single blue blemish; healing should blend it toward the surround.
        let id = UUID()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fillEllipse(in: CGRect(x: 45, y: 45, width: 10, height: 10))
        let img = ctx.makeImage()!
        let record = ProjectLayerRecord(id: id, name: "L", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)), imageFile: "\(id.uuidString).png")
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: id, layers: [record])
        let doc = await store.insert(ProjectSnapshot(manifest: manifest,
            images: [id: ImportedImage(image: img, thumbnail: img, name: "L")]), url: nil, name: "t")
        let before = try await pixel(store, doc, 50, 50)
        XCTAssertGreaterThan(before.2, before.0, "the blemish starts blue")
        _ = try await healStroke(Params(["document": doc, "layer": id.uuidString, "diameter": 16,
            "path": [["x": 50, "y": 50], ["x": 51, "y": 50]]]), store)
        let after = try await pixel(store, doc, 50, 50)
        XCTAssertNotEqual(before.2, after.2, "healing should have rebuilt the blemish from the red surround")
    }

    func testSelectionLimitsPainting() async throws {
        let store = DocumentStore()
        let (doc, layer) = await makeDoc(store, fill: nil)
        // Select a small box, then paint a long line — only the box should take paint.
        _ = try await applySelection(Params(["document": doc, "shape": "rect",
            "x": 45, "y": 45, "width": 10, "height": 10]), store)
        _ = try await paintStroke(Params(["document": doc, "layer": layer, "tool": "brush",
            "diameter": 12, "red": 1.0, "path": line(y: 50)]), store)
        let inside = try await pixel(store, doc, 50, 50)
        let outside = try await pixel(store, doc, 25, 50)
        XCTAssertGreaterThan(inside.3, 0, "inside the selection paints")
        XCTAssertEqual(outside.3, 0, "outside the selection is masked out")
    }

    func testCropCanvasShrinksTheDocument() async throws {
        let store = DocumentStore()
        let (doc, _) = await makeDoc(store, fill: (0, 255, 0, 255))
        _ = try await cropCanvas(Params(["document": doc, "x": 10, "y": 10, "width": 40, "height": 30]), store)
        let snapshot = try await store.snapshot(doc)
        XCTAssertEqual(snapshot.manifest.width, 40)
        XCTAssertEqual(snapshot.manifest.height, 30)
    }

    func testGaussianBlurSoftensAnEdge() async throws {
        let store = DocumentStore()
        // Sharp red/blue edge at x=50; blurring spreads colour across it.
        let id = UUID()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        let img = ctx.makeImage()!
        let record = ProjectLayerRecord(id: id, name: "L", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)), imageFile: "\(id.uuidString).png")
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: id, layers: [record])
        let doc = await store.insert(ProjectSnapshot(manifest: manifest,
            images: [id: ImportedImage(image: img, thumbnail: img, name: "L")]), url: nil, name: "t")
        let before = try await pixel(store, doc, 48, 50)
        XCTAssertLessThan(before.2, 50, "before blur the pixel just left of the edge is pure red")
        _ = try await applyFilter(Params(["document": doc, "layer": id.uuidString,
            "filter": "gaussian_blur", "radius": 8.0]), store)
        let after = try await pixel(store, doc, 48, 50)
        XCTAssertGreaterThan(after.2, before.2, "blur should have bled blue across the edge")
    }

    func testMergeLayersProducesOneLayer() async throws {
        let store = DocumentStore()
        // Two opaque layers; merging leaves a single layer whose pixels are still there.
        let a = UUID(), b = UUID()
        let red = solid(100, 100, (255, 0, 0, 255)), blue = solid(100, 100, (0, 0, 255, 128))
        let ra = ProjectLayerRecord(id: a, name: "A", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)), imageFile: "\(a.uuidString).png")
        let rb = ProjectLayerRecord(id: b, name: "B", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)), imageFile: "\(b.uuidString).png")
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: a, layers: [ra, rb])
        let doc = await store.insert(ProjectSnapshot(manifest: manifest,
            images: [a: ImportedImage(image: red, thumbnail: red, name: "A"),
                     b: ImportedImage(image: blue, thumbnail: blue, name: "B")]), url: nil, name: "t")
        _ = try await mergeLayers(Params(["document": doc, "layers": [a.uuidString, b.uuidString]]), store)
        let snapshot = try await store.snapshot(doc)
        XCTAssertEqual(snapshot.manifest.layers.count, 1, "merge should collapse two layers into one")
        let merged = try await pixel(store, doc, 50, 50)
        XCTAssertGreaterThan(merged.3, 0, "the merged layer keeps its pixels")
    }

    func testFlattenDocumentCollapsesEverything() async throws {
        let store = DocumentStore()
        let a = UUID(), b = UUID()
        let red = solid(100, 100, (255, 0, 0, 255)), green = solid(100, 100, (0, 255, 0, 255))
        let ra = ProjectLayerRecord(id: a, name: "A", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)), imageFile: "\(a.uuidString).png")
        let rb = ProjectLayerRecord(id: b, name: "B", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)), imageFile: "\(b.uuidString).png")
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: a, layers: [ra, rb])
        let doc = await store.insert(ProjectSnapshot(manifest: manifest,
            images: [a: ImportedImage(image: red, thumbnail: red, name: "A"),
                     b: ImportedImage(image: green, thumbnail: green, name: "B")]), url: nil, name: "t")
        _ = try await flattenDocument(Params(["document": doc]), store)
        let flat = try await store.snapshot(doc)
        XCTAssertEqual(flat.manifest.layers.count, 1)
    }
}
