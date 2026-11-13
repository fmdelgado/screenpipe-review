// Launcher so macOS Screen Recording permission applies to this one program only.
// Runs review.sh as a child process (this binary stays the "responsible" process).
import Foundation
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/bash")
p.arguments = [NSHomeDirectory() + "/screenpipe-review/review.sh"]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
