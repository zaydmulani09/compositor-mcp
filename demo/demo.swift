// Headless end-to-end demo on a real photo: drives the built compositor-mcp binary
// over real JSON-RPC (the protocol an agent speaks) to remove power lines from the sky.
// It imports the photo, then runs a two-tool edit — heal_stroke to erase a bold cable
// out of the clear sky, then clone_stamp_stroke to patch a second one with nearby sky —
// exporting a frame after import, after the heal, and after the clone. It records every
// JSON-RPC call and fails unless the frames actually differ, so a green run proves pixels
// changed at each step, not just "no crash".
//
//   swift demo/demo.swift [path-to-binary] [output-dir] [source-image]
//
// Defaults: .build/debug/compositor-mcp, ./demo-output, demo/source.webp

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let binary = args.count > 1 ? args[1] : ".build/debug/compositor-mcp"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "demo-output")
let sourceImage = URL(fileURLWithPath: args.count > 3 ? args[3] : "demo/source.webp")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Image helpers

func loadCGImage(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("could not read \(url.path)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not create \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fail("could not write \(url.lastPathComponent)") }
}

func loadRGBA(_ url: URL) -> (data: [UInt8], w: Int, h: Int) {
    let image = loadCGImage(url)
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

/// Pixels differing by more than 16 on any channel, over the whole frame.
func changedPixels(_ a: URL, _ b: URL) -> (changed: Int, total: Int) {
    let x = loadRGBA(a), y = loadRGBA(b)
    guard x.w == y.w, x.h == y.h else { fail("frame sizes differ") }
    var changed = 0
    for i in stride(from: 0, to: x.data.count, by: 4) {
        let dr = abs(Int(x.data[i]) - Int(y.data[i]))
        let dg = abs(Int(x.data[i + 1]) - Int(y.data[i + 1]))
        let db = abs(Int(x.data[i + 2]) - Int(y.data[i + 2]))
        if max(dr, dg, db) > 16 { changed += 1 }
    }
    return (changed, x.w * x.h)
}

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

// MARK: - Prepare the photo (webp -> png at full resolution)

let base = loadCGImage(sourceImage)
let (w, h) = (base.width, base.height)
let inputURL = outDir.appendingPathComponent("input.png")
writePNG(base, to: inputURL)

let step0 = outDir.appendingPathComponent("step0_imported.png")
let step1 = outDir.appendingPathComponent("step1_healed.png")
let step2 = outDir.appendingPathComponent("step2_cloned.png")

// MARK: - The edit, over JSON-RPC
//
// Coordinates are canvas (top-left) pixels in the photo's own 1920x1280 space. The two
// targets are bold cables in the clear upper sky. Tweak and re-run if a stroke misses.

let healLine: [[String: Int]] = [["x": 280, "y": 300], ["x": 480, "y": 245], ["x": 700, "y": 190],
                                 ["x": 920, "y": 135], ["x": 1120, "y": 85]]
let cloneLine: [[String: Int]] = [["x": 1300, "y": 150], ["x": 1500, "y": 110], ["x": 1700, "y": 80]]
let cloneSource: [String: Int] = ["x": 1300, "y": 270]  // clean blue sky below the cable

let server = Server(binary)
server.send("initialize", ["protocolVersion": "2025-06-18"])

let created = server.tool("create_document", ["width": w, "height": h, "name": "powerlines"])
let doc = token(after: "Document handle: ", in: created)
let imported = server.tool("import_image", ["document": doc, "path": inputURL.path])
let layer = token(after: "Layer id: ", in: imported)

server.tool("export_image", ["document": doc, "path": step0.path])

server.tool("heal_stroke", ["document": doc, "layer": layer, "diameter": 34, "path": healLine])
server.tool("export_image", ["document": doc, "path": step1.path])

server.tool("clone_stamp_stroke", ["document": doc, "layer": layer, "diameter": 34,
                                    "source_point": cloneSource, "path": cloneLine])
server.tool("export_image", ["document": doc, "path": step2.path])

server.finish()

try server.calls.joined(separator: "\n").write(to: outDir.appendingPathComponent("calls.jsonl"),
                                                atomically: true, encoding: .utf8)
try server.responses.joined(separator: "\n").write(to: outDir.appendingPathComponent("responses.jsonl"),
                                                    atomically: true, encoding: .utf8)

// MARK: - Prove each step changed pixels

let healDelta = changedPixels(step0, step1)
let cloneDelta = changedPixels(step1, step2)
let overall = changedPixels(step0, step2)
func pct(_ d: (changed: Int, total: Int)) -> String { String(format: "%.3f%%", Double(d.changed) / Double(d.total) * 100) }
print("photo: \(w)x\(h)")
print("heal changed:  \(healDelta.changed) px (\(pct(healDelta)))")
print("clone changed: \(cloneDelta.changed) px (\(pct(cloneDelta)))")
print("overall:       \(overall.changed) px (\(pct(overall)))")

// Each tool should visibly touch the frame; a stroke that missed its cable shows up here as ~0.
if healDelta.changed < 200 { fail("heal_stroke barely changed anything — it likely missed the cable") }
if cloneDelta.changed < 200 { fail("clone_stamp_stroke barely changed anything — it likely missed the cable") }
print("demo OK — three frames exported, each tool visibly changed the photo; calls in calls.jsonl")
