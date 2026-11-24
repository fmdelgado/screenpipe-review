// Launcher so macOS Screen Recording permission applies to this one program only.
// Runs review.sh as a child process (this binary stays the "responsible" process).
import Foundation

let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let localScript = execURL.deletingLastPathComponent().appendingPathComponent("review.sh").path
let script = FileManager.default.isExecutableFile(atPath: localScript)
    ? localScript
    : NSHomeDirectory() + "/screenpipe-review/review.sh"

let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/bash")
p.arguments = [script]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
