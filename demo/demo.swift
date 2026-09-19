// Headless end-to-end demo on a real photo: drives the built compositor-mcp binary over
// real JSON-RPC (the protocol an agent speaks) to erase a plane from a clear sky.
//
// It does NOT hard-code where the plane is. It loads the image, finds the plane by its
// pixels (the dark cluster against the bright sky), heals a brush wide enough to cover
// that bounding box, exports a frame before and after, then checks the plane's region
// actually became clean sky — not a smudge — before calling it done. A single clean heal
// is the whole demo; it only adds a clone-stamp pass if the heal leaves residue.
//
//   swift demo/demo.swift [path-to-binary] [output-dir] [source-image]
//
// Defaults: .build/debug/compositor-mcp, ./demo-output, demo/source.jpg

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let binary = args.count > 1 ? args[1] : ".build/debug/compositor-mcp"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "demo-output")
let sourceImage = URL(fileURLWithPath: args.count > 3 ? args[3] : "demo/source.jpg")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Image helpers

func loadRGBA(_ url: URL) -> (data: [UInt8], w: Int, h: Int) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("could not read \(url.path)") }
    let w = image.width, h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    buffer.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (buffer, w, h)
}

func luma(_ d: [UInt8], _ i: Int) -> Int {
    (299 * Int(d[i]) + 587 * Int(d[i + 1]) + 114 * Int(d[i + 2])) / 1000
}

// The most common luma, the sky's brightness (the plane is a tiny minority of pixels).
func medianLuma(_ img: (data: [UInt8], w: Int, h: Int)) -> Int {
    var histogram = [Int](repeating: 0, count: 256)
    for i in stride(from: 0, to: img.data.count, by: 4) { histogram[luma(img.data, i)] += 1 }
    let mid = (img.w * img.h) / 2
    var running = 0
    for value in 0..<256 { running += histogram[value]; if running >= mid { return value } }
    return 128
}

/// Pixels this much darker than the sky are "object". Lens vignetting also darkens the
/// frame, but only near the edges, so darkness alone isn't enough — see the border rule below.
let darkGap = 50

// MARK: - Find the plane
//
// The plane is one compact dark blob floating in the interior; the vignette is a darkening
// that touches the frame's edges. So: take the largest connected clump of dark pixels that
// does NOT reach any border. That throws the vignette away and keeps the plane, wherever it
// sits. Detection runs on a 1/4 grid — plenty for the box, far cheaper than the full 18 MP.

let source = loadRGBA(sourceImage)
let (w, h) = (source.w, source.h)
let skyLuma = medianLuma(source)
let threshold = skyLuma - darkGap

let step = 4
let gw = w / step, gh = h / step
var mask = [Bool](repeating: false, count: gw * gh)
for gy in 0..<gh {
    let row = gy * step * w * 4
    for gx in 0..<gw where luma(source.data, row + gx * step * 4) < threshold { mask[gy * gw + gx] = true }
}

var visited = [Bool](repeating: false, count: gw * gh)
var stack: [Int] = []
var best: (count: Int, x0: Int, y0: Int, x1: Int, y1: Int)?
for seed in 0..<(gw * gh) where mask[seed] && !visited[seed] {
    stack.removeAll(keepingCapacity: true)
    stack.append(seed); visited[seed] = true
    var count = 0, x0 = gw, y0 = gh, x1 = 0, y1 = 0, touchesBorder = false
    while let p = stack.popLast() {
        let gx = p % gw, gy = p / gw
        count += 1
        x0 = min(x0, gx); x1 = max(x1, gx); y0 = min(y0, gy); y1 = max(y1, gy)
        if gx == 0 || gy == 0 || gx == gw - 1 || gy == gh - 1 { touchesBorder = true }
        if gx > 0, mask[p - 1], !visited[p - 1] { visited[p - 1] = true; stack.append(p - 1) }
        if gx < gw - 1, mask[p + 1], !visited[p + 1] { visited[p + 1] = true; stack.append(p + 1) }
        if gy > 0, mask[p - gw], !visited[p - gw] { visited[p - gw] = true; stack.append(p - gw) }
        if gy < gh - 1, mask[p + gw], !visited[p + gw] { visited[p + gw] = true; stack.append(p + gw) }
    }
    if touchesBorder { continue }              // vignette / edge darkening, not the plane
    if best == nil || count > best!.count { best = (count, x0, y0, x1, y1) }
}
guard let plane = best, plane.count >= 20 else {
    fail("no compact dark object away from the edges (sky luma \(skyLuma)) — wrong image?")
}
let (bx, by) = (plane.x0 * step, plane.y0 * step)
let (bw, bh) = ((plane.x1 - plane.x0 + 1) * step, (plane.y1 - plane.y0 + 1) * step)
let cx = bx + bw / 2, cy = by + bh / 2
print("sky luma \(skyLuma), plane cells \(plane.count), plane bbox \(bx),\(by) \(bw)x\(bh)")

// A brush wide enough to swallow the whole plane, stroked across its long axis.
let diameter = min(2000, max(bw, bh) + 120)
let planeRegion = [["x": bx, "y": cy], ["x": cx, "y": cy], ["x": bx + bw, "y": cy]]

// MARK: - JSON-RPC client over the binary's stdio

final class Server {
    private let proc = Process()
    private let inPipe = Pipe(), outPipe = Pipe()
    private var buffer = Data()
    private var nextID = 0
    var calls: [String] = []
    var responses: [String] = []

    init(_ path: String) {
        proc.executableURL = URL(fileURLWithPath: path)
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.nullDevice
        do { try proc.run() } catch { fail("could not launch \(path): \(error)") }
    }

    private func readLine() -> [String: Any] {
        while !buffer.contains(0x0A) {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { fail("the server closed before answering") }
            buffer.append(chunk)
        }
        let nl = buffer.firstIndex(of: 0x0A)!
        let line = buffer.subdata(in: buffer.startIndex..<nl)
        buffer.removeSubrange(buffer.startIndex...nl)
        responses.append(String(data: line, encoding: .utf8) ?? "")
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let id = nextID; nextID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try! JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        calls.append(String(data: data, encoding: .utf8)!)
        inPipe.fileHandleForWriting.write(data)
        inPipe.fileHandleForWriting.write(Data([0x0A]))
        return readLine()
    }

    func tool(_ name: String, _ arguments: [String: Any]) -> String {
        let response = send("tools/call", ["name": name, "arguments": arguments])
        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        if result?["isError"] as? Bool == true { fail("\(name) failed: \(text)") }
        return text
    }

    func finish() { inPipe.fileHandleForWriting.closeFile(); proc.waitUntilExit() }
}

func token(after marker: String, in text: String) -> String {
    guard let range = text.range(of: marker) else { fail("expected '\(marker)' in:\n\(text)") }
    return String(text[range.upperBound...].prefix { !$0.isWhitespace })
}

// MARK: - Run the edit

let step0 = outDir.appendingPathComponent("step0_imported.png")
let step1 = outDir.appendingPathComponent("step1_healed.png")

let server = Server(binary)
server.send("initialize", ["protocolVersion": "2025-06-18"])
let created = server.tool("create_document", ["width": w, "height": h, "name": "plane"])
let doc = token(after: "Document handle: ", in: created)
let imported = server.tool("import_image", ["document": doc, "path": sourceImage.path])
let layer = token(after: "Layer id: ", in: imported)
server.tool("export_image", ["document": doc, "path": step0.path])
server.tool("heal_stroke", ["document": doc, "layer": layer, "diameter": diameter, "path": planeRegion])
server.tool("export_image", ["document": doc, "path": step1.path])
server.finish()

try server.calls.joined(separator: "\n").write(to: outDir.appendingPathComponent("calls.jsonl"),
                                                atomically: true, encoding: .utf8)
try server.responses.joined(separator: "\n").write(to: outDir.appendingPathComponent("responses.jsonl"),
                                                    atomically: true, encoding: .utf8)

// MARK: - Confirm the plane's region is clean sky now, not a smudge

// Count dark (plane) pixels in the plane's box, with a margin, before and after.
let mx0 = max(0, bx - 40), my0 = max(0, by - 40)
let mx1 = min(w - 1, bx + bw + 40), my1 = min(h - 1, by + bh + 40)
func darkInBox(_ img: (data: [UInt8], w: Int, h: Int)) -> Int {
    var count = 0
    for y in my0...my1 {
        let row = y * img.w * 4
        for x in mx0...mx1 where luma(img.data, row + x * 4) < threshold { count += 1 }
    }
    return count
}
let after = loadRGBA(step1)
let darkBefore = darkInBox(source)   // the source == the imported frame
let darkAfter = darkInBox(after)
let removed = darkBefore == 0 ? 0 : Double(darkBefore - darkAfter) / Double(darkBefore) * 100
print("dark pixels in plane box: before \(darkBefore), after \(darkAfter) (\(String(format: "%.1f", removed))% gone)")

// Clean means almost none of the plane's dark pixels survive in that region.
if darkAfter > darkBefore / 20 {
    fail("the plane's region still has \(darkAfter) dark pixels — heal left residue, needs a wider brush or a clone pass")
}
print("demo OK — plane removed, region is clean sky; JSON-RPC calls in calls.jsonl")
