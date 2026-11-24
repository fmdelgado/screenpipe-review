# screenpipe-review

Live universal on-screen problem solver for a mirrored window (`MeowDisplay`) or a connected monitor (built-in Mac display or external screen). Every 2s it captures the target window or display, checks for both text (macOS Vision OCR) and visual changes (fast grayscale grid diff), and streams a clean, direct solution using the local Claude Code CLI (subscription auth, no API key).

Works for any kind of challenge on screen — multiple-choice quizzes, math/logic/visual puzzles, coding problems (empty editors or debugging existing code), stack traces/CLI errors, SQL/regex/formulas, diagrams/charts, interview/open-ended questions, forms, and everyday screen tasks.

## Setup
```bash
swiftc -O helper.swift -o helper
swiftc -O reviewer.swift -o reviewer
ln -sf "$PWD/live-review" ~/.local/bin/live-review
```
Grant Screen Recording permission to your terminal, then run `live-review` (`q` or `Ctrl+C` stops).

## Usage

```bash
# Default: watch the MeowDisplay window (web lookup ON, 2s poll)
live-review

# List connected screens (shows display numbers, roles, and monitor names)
live-review --list-screens

# Watch a monitor in a dual-screen setup
live-review --screen external   # external monitor (or --screen 2, or monitor name e.g. --screen Acer)
live-review --screen builtin    # Mac's built-in display (or --screen 1)

# Start with web lookup OFF for fastest direct solving
live-review --screen external --no-web
```

### Live Controls (press anytime while running)
- `w` — toggle web lookup (`WebSearch`/`WebFetch`) **ON / OFF** immediately on the fly
- `Space` or `Enter` — force an immediate solve of the current screen right now
- `p` — pause / resume watching
- `c` — clear screen and reset saved context/history for a fresh topic
- `q` (or `Ctrl+C`) — quit cleanly

### Options (CLI flags or environment variables)
- `-s, --screen <target>` / `SCREEN_TARGET=<target>` — `1`, `2`, `external`, `builtin`, `main`, `secondary`, or monitor name substring
- `-w, --window <app>` / `WINDOW_MATCH=<app>` — app window owner name (default: `MeowDisplay`)
- `-i, --interval <sec>` / `INTERVAL=2` — poll interval in seconds (default: `2`)
- `-m, --model <model>` / `REVIEW_MODEL=claude-sonnet-5-5` — Claude Code CLI model (default: `claude-sonnet-5-5`)
- `--web` / `--no-web` / `WEB_SEARCH=1|0` — initial web lookup mode (default: `1` = ON)

## Tests
```bash
./test.sh
```

Runtime data (`state/`, `output/`) contains screen captures and is git-ignored.
