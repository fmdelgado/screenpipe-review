# screenpipe-review

Live universal on-screen problem solver for a mirrored window (`MeowDisplay`) or a connected monitor (built-in Mac display or external screen). Every 2s it captures the target window or display, checks for meaningful visual/text changes (ignoring clocks, timers, cursor blink, and OCR jitter), and replaces the terminal view with **only the direct solution to the present question on screen** using the local Claude Code CLI (subscription auth, no API key). Full history is still kept quietly on disk in `output/history.md`.

Works for any kind of challenge on screen — multiple-choice quizzes, math/logic/visual puzzles, coding problems (empty editors or debugging existing code), stack traces/CLI errors, SQL/regex/formulas, diagrams/charts, long multi-scroll data-quality/case work samples, interview/open-ended questions, forms, and everyday screen tasks.

### Multi-scroll problems (long work samples & specs)
- **Automatic scroll-settle capture:** when you scroll through a long problem, `live-review` waits `1.2s` for scrolling to settle and collects consecutive views into a rolling multi-image batch (up to 5 pages), sending them together in **one** Claude call at full visual fidelity.
- **Completeness gate:** if critical parts of a problem are visibly cut off (e.g., a truncated table row, a referenced denominator table, or unseen questions below), the solver briefly prompts `⬇ Scroll down to capture the rest` instead of guessing, keeps your captured pages buffered, and delivers the complete solution once you scroll down. Press `Space` anytime to force an immediate answer with what's captured so far.
- Switching to an unrelated problem automatically resets the page buffer (or press `c` anytime).

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
