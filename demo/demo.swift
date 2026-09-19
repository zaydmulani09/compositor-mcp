// Headless end-to-end demo: drives the built compositor-mcp binary over real
// JSON-RPC (the same protocol an agent speaks), on a sample image with an obvious
// blemish. It exports before.png (right after import) and after.png (after a brush
// stroke and a spot heal), records every JSON-RPC call it sent, and fails unless the
// two PNGs actually differ — so a green run proves pixels changed, not just "no crash".
//
//   swift demo/demo.swift [path-to-binary] [output-dir]
//
// Defaults: .build/debug/compositor-mcp, ./demo-output

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let binary = args.count > 1 ? args[1] : ".build/debug/compositor-mcp"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "demo-output")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - PNG helpers

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not create \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fail("could not write \(url.lastPathComponent)") }
}

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

// A photo-ish gradient with a few shapes and one obvious dark blemish at (300, 300).
func makeSample(_ url: URL) {
    let w = 1024, h = 768
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.20, green: 0.45, blue: 0.75, alpha: 1),
        CGColor(srgbRed: 0.85, green: 0.80, blue: 0.55, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.5, blue: 0.3, alpha: 0.9))
    ctx.fillEllipse(in: CGRect(x: 620, y: 200, width: 260, height: 260))
    // The blemish: a small near-black blob to heal away.
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.04, blue: 0.06, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 272, y: 272, width: 56, height: 56))
    guard let image = ctx.makeImage() else { fail("could not render the sample") }
    writePNG(image, to: url)
}

// MARK: - JSON-RPC client over the binary's stdio

final class Server {
    private let proc = Process()
    private let inPipe = Pipe(), outPipe = Pipe()
    private var buffer = Data()
    private var nextID = 0
    var calls: [String] = []       // every request line sent
    var responses: [String] = []   // every response line received

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

    /// A tools/call, returning the tool's text output (and failing on a tool error).
    func tool(_ name: String, _ arguments: [String: Any]) -> String {
        let response = send("tools/call", ["name": name, "arguments": arguments])
        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        if result?["isError"] as? Bool == true { fail("\(name) failed: \(text)") }
        return text
    }

    func finish() {
        inPipe.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
    }
}

// The token right after a marker like "Document handle: " or "Layer id: ".
func token(after marker: String, in text: String) -> String {
    guard let range = text.range(of: marker) else { fail("expected '\(marker)' in:\n\(text)") }
    let rest = text[range.upperBound...]
    return String(rest.prefix { !$0.isWhitespace })
}

// MARK: - Run the sequence

let sampleURL = outDir.appendingPathComponent("sample.png")
let beforeURL = outDir.appendingPathComponent("before.png")
let afterURL = outDir.appendingPathComponent("after.png")
makeSample(sampleURL)

let server = Server(binary)
server.send("initialize", ["protocolVersion": "2025-06-18"])

let created = server.tool("create_document", ["width": 1024, "height": 768, "name": "demo"])
let doc = token(after: "Document handle: ", in: created)

let imported = server.tool("import_image", ["document": doc, "path": sampleURL.path, "fit": true])
let layer = token(after: "Layer id: ", in: imported)

// before.png: exactly what was imported, no edits yet.
server.tool("export_image", ["document": doc, "path": beforeURL.path])

// A bright brush stroke across the frame, then heal the blemish at (300, 300).
server.tool("paint_stroke", [
    "document": doc, "layer": layer, "tool": "brush",
    "diameter": 26, "hardness": 0.4, "opacity": 0.9, "red": 0.95, "green": 0.1, "blue": 0.1,
    "path": [["x": 150, "y": 150], ["x": 400, "y": 300], ["x": 650, "y": 430], ["x": 874, "y": 618]],
])
server.tool("heal_stroke", [
    "document": doc, "layer": layer, "diameter": 64,
    "path": [["x": 300, "y": 300], ["x": 302, "y": 300]],
])

server.tool("export_image", ["document": doc, "path": afterURL.path])
server.finish()

// Record the literal JSON-RPC sequence — this is what proves an agent drove the edit.
try server.calls.joined(separator: "\n").write(to: outDir.appendingPathComponent("calls.jsonl"),
                                                atomically: true, encoding: .utf8)
try server.responses.joined(separator: "\n").write(to: outDir.appendingPathComponent("responses.jsonl"),
                                                    atomically: true, encoding: .utf8)

// MARK: - Prove the pixels actually changed

let before = loadRGBA(beforeURL), after = loadRGBA(afterURL)
guard before.w == after.w, before.h == after.h else { fail("before/after sizes differ") }
var changed = 0
for i in stride(from: 0, to: before.data.count, by: 4) {
    let dr = abs(Int(before.data[i]) - Int(after.data[i]))
    let dg = abs(Int(before.data[i + 1]) - Int(after.data[i + 1]))
    let db = abs(Int(before.data[i + 2]) - Int(after.data[i + 2]))
    if max(dr, dg, db) > 16 { changed += 1 }
}
let total = before.w * before.h
print("changed pixels: \(changed) of \(total) (\(String(format: "%.2f", Double(changed) / Double(total) * 100))%)")
// The brush stroke alone covers well over a thousand pixels; require a real, visible delta.
if changed < 1000 { fail("before.png and after.png are effectively identical — no visible edit") }
print("demo OK — before.png and after.png differ visibly; JSON-RPC calls in calls.jsonl")
