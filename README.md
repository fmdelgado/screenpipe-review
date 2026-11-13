# screenpipe-review

Live code reviewer for a mirrored screen (MeowDisplay). Every 10s it screenshots the window,
OCRs it on-device (macOS Vision), and — only when the screen changed — asks the local
Claude Code CLI (subscription auth, no API key) for minimal fixes checked against any
problem definition it has read on screen.

## Setup
```
swiftc -O helper.swift -o helper
swiftc -O reviewer.swift -o reviewer
ln -sf "$PWD/live-review" ~/.local/bin/live-review
```
Grant Screen Recording permission to your terminal, then run `live-review` (Ctrl+C stops).

Options: `INTERVAL=30`, `REVIEW_MODEL=haiku`, `WINDOW_MATCH=<app name>`.

Runtime data (`state/`, `output/`) contains screen captures and is git-ignored.
