// helper winid <AppName>   -> prints CGWindowID of the app's largest on-screen window
// helper ocr <image.png>   -> prints text recognized by macOS Vision (on-device)
import Foundation
import CoreGraphics
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: helper winid <app> | ocr <png>\n", stderr); exit(2) }

if args[1] == "winid" {
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
} else if args[1] == "ocr" {
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
}
