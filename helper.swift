// helper winid <AppName>                    -> prints CGWindowID of the app's largest on-screen window
// helper ocr <image.png>                    -> prints text recognized by macOS Vision (on-device)
// helper screens                            -> lists active displays (1-based index matching screencapture -D)
// helper screen <target>                    -> resolves index (1, 2), role (builtin, external, main, secondary), or name substring
// helper vdiff <imgA> <imgB>                -> prints integer % (0-100) of non-menubar visual grid cells that changed
// helper vdiff-cells <imgA> <imgB>          -> prints "<changed_cells>\t<pct>" on a 240x150 non-menubar grayscale grid
// helper mask <src> <dst> <screen> <title>  -> masks any on-screen window matching <title> on <screen> (exit 1 if none)
// helper prep <src> <dst> [maxpx]           -> downscales image to max dimension (default 1920) and writes JPEG/PNG
import Foundation
import CoreGraphics
import ImageIO
import Vision
import AppKit

struct DisplayInfo {
    let index: Int
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let width: Int
    let height: Int
}

func activeDisplays() -> [DisplayInfo] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    let nsScreens = NSScreen.screens
    return ids.prefix(Int(count)).enumerated().map { (offset, id) in
        let b = CGDisplayBounds(id)
        let match = nsScreens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
        let fallback = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display \(offset + 1)"
        return DisplayInfo(
            index: offset + 1,
            id: id,
            name: match?.localizedName ?? fallback,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            width: Int(b.width.rounded()),
            height: Int(b.height.rounded())
        )
    }
}

func resolveDisplay(_ rawTarget: String, in displays: [DisplayInfo]) -> DisplayInfo? {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }
    if let idx = Int(target) {
        return displays.first { $0.index == idx }
    }
    switch target.lowercased() {
    case "main", "primary":
        return displays.first { $0.isMain }
    case "secondary":
        return displays.first { !$0.isMain }
    case "builtin", "built-in", "internal":
        return displays.first { $0.isBuiltin }
    case "external", "monitor":
        return displays.first { !$0.isBuiltin }
    default:
        return displays.first { $0.name.localizedCaseInsensitiveContains(target) }
    }
}

func loadCGImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func grayscaleGrid(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: width * height)
    let cs = CGColorSpaceCreateDeviceGray()
    let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
        guard let base = ptr.baseAddress,
              let ctx = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return ok ? buf : nil
}

func prepImage(srcPath: String, dstPath: String, maxDim: Int) -> Bool {
    guard let cg = loadCGImage(srcPath), maxDim > 0 else { return false }
    let srcW = cg.width
    let srcH = cg.height
    let longest = max(srcW, srcH)
    let outW: Int
    let outH: Int
    if longest > maxDim {
        let scale = Double(maxDim) / Double(longest)
        outW = max(1, Int((Double(srcW) * scale).rounded()))
        outH = max(1, Int((Double(srcH) * scale).rounded()))
    } else {
        outW = srcW
        outH = srcH
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: outW,
        height: outH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return false }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
    guard let outCG = ctx.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: outCG)
    let lower = dstPath.lowercased()
    let data: Data?
    if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
        data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    } else {
        data = rep.representation(using: .png, properties: [:])
    }
    guard let outData = data else { return false }
    do {
        try outData.write(to: URL(fileURLWithPath: dstPath), options: .atomic)
        return true
    } catch {
        return false
    }
}

func maskWindowOnDisplay(srcPath: String, dstPath: String, screenTarget: String, titleSubstr: String) -> Bool {
    let displays = activeDisplays()
    guard let disp = resolveDisplay(screenTarget, in: displays) else { return false }
    let dBounds = CGDisplayBounds(disp.id)
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []

    var maskRects: [CGRect] = []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let name = w[kCGWindowName as String] as? String,
              name.localizedCaseInsensitiveContains(titleSubstr),
              let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        let wr = CGRect(
            x: b["X"] ?? 0,
            y: b["Y"] ?? 0,
            width: b["Width"] ?? 0,
            height: b["Height"] ?? 0
        )
        let inter = wr.intersection(dBounds)
        if !inter.isNull && inter.width > 10 && inter.height > 10 {
            maskRects.append(inter)
        }
    }
    guard !maskRects.isEmpty, let cg = loadCGImage(srcPath) else { return false }

    let imgW = cg.width
    let imgH = cg.height
    let scaleX = Double(imgW) / max(1.0, Double(dBounds.width))
    let scaleY = Double(imgH) / max(1.0, Double(dBounds.height))

    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: imgW,
        height: imgH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return false }

    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    for r in maskRects {
        // CGWindowBounds is top-down relative to main display origin; CGContext is bottom-up.
        let relX = (Double(r.origin.x) - Double(dBounds.origin.x)) * scaleX
        let relTopY = (Double(r.origin.y) - Double(dBounds.origin.y)) * scaleY
        let rw = Double(r.size.width) * scaleX
        let rh = Double(r.size.height) * scaleY
        let cgY = Double(imgH) - relTopY - rh
        ctx.fill(CGRect(x: relX, y: cgY, width: rw, height: rh))
    }

    guard let outCG = ctx.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: outCG)
    guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try pngData.write(to: URL(fileURLWithPath: dstPath), options: .atomic)
        return true
    } catch {
        return false
    }
}

func usage() -> Never {
    fputs("usage: helper winid <app> | ocr <png> | screens | screen <target> | vdiff <imgA> <imgB> | vdiff-cells <imgA> <imgB> | mask <src> <dst> <screen> <title> | prep <src> <dst> [max_dim]\n", stderr)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

switch args[1] {
case "winid":
    guard args.count >= 3 else { usage() }
    let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
    var best: (id: Int, area: Double) = (0, 0)
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String,
              owner.lowercased() == args[2].lowercased(),
              (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
        if area > best.area, let id = w[kCGWindowNumber as String] as? Int { best = (id, area) }
    }
    if best.id == 0 { exit(1) }
    print(best.id)

case "ocr":
    guard args.count >= 3 else { usage() }
    guard let img = NSImage(contentsOfFile: args[2]),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false   // keep code tokens as-is
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    let obs = (req.results ?? []).sorted {
        // top-to-bottom, then left-to-right
        abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.005
            ? $0.boundingBox.midY > $1.boundingBox.midY
            : $0.boundingBox.minX < $1.boundingBox.minX
    }
    for o in obs { if let t = o.topCandidates(1).first?.string { print(t) } }

case "screens":
    let displays = activeDisplays()
    if displays.isEmpty { exit(1) }
    for d in displays {
        var tags = [d.isBuiltin ? "builtin" : "external"]
        if d.isMain { tags.append("main") }
        print("\(d.index): \(d.name) [\(tags.joined(separator: ", "))] (\(d.width)x\(d.height))")
    }

case "screen":
    guard args.count >= 3 else { usage() }
    let displays = activeDisplays()
    guard let d = resolveDisplay(args[2], in: displays) else { exit(1) }
    print("\(d.index)\t\(d.name)")

case "vdiff":
    guard args.count >= 4 else { usage() }
    let gridW = 48
    let gridH = 32
    guard let cgA = loadCGImage(args[2]),
          let cgB = loadCGImage(args[3]),
          let bufA = grayscaleGrid(cgA, width: gridW, height: gridH),
          let bufB = grayscaleGrid(cgB, width: gridW, height: gridH) else { exit(1) }
    // Skip top row (row 0 = top ~3.1% of screen) to ignore macOS menu-bar clock/status ticks
    var changed = 0
    let startIdx = gridW
    let total = (gridH - 1) * gridW
    for i in startIdx..<(gridW * gridH) {
        if abs(Int(bufA[i]) - Int(bufB[i])) > 12 {
            changed += 1
        }
    }
    print((changed * 100) / total)

case "vdiff-cells":
    guard args.count >= 4 else { usage() }
    let gridW = 240
    let gridH = 150
    let skipRows = 5 // top ~3.3% (macOS menu bar)
    guard let cgA = loadCGImage(args[2]),
          let cgB = loadCGImage(args[3]),
          let bufA = grayscaleGrid(cgA, width: gridW, height: gridH),
          let bufB = grayscaleGrid(cgB, width: gridW, height: gridH) else { exit(1) }
    var changed = 0
    let startIdx = skipRows * gridW
    let total = (gridH - skipRows) * gridW
    for i in startIdx..<(gridW * gridH) {
        if abs(Int(bufA[i]) - Int(bufB[i])) > 12 {
            changed += 1
        }
    }
    let pct = (changed * 100) / total
    print("\(changed)\t\(pct)")

case "mask":
    guard args.count >= 6 else { usage() }
    if !maskWindowOnDisplay(srcPath: args[2], dstPath: args[3], screenTarget: args[4], titleSubstr: args[5]) {
        exit(1)
    }

case "prep":
    guard args.count >= 4 else { usage() }
    let maxDim = args.count >= 5 ? (Int(args[4]) ?? 1920) : 1920
    guard prepImage(srcPath: args[2], dstPath: args[3], maxDim: maxDim) else { exit(1) }

default:
    usage()
}
