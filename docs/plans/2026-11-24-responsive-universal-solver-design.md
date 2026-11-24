# Responsive Universal Screen Solver Design

**Date:** 2026-11-24  
**Status:** Approved

## Goal

Transform `screenpipe-review` from a slow, code-bug-only reviewer into a fast, responsive **universal on-screen problem solver** that:
1. Detects both text and visual screen changes within seconds.
2. Actively suggests a direct, actionable solution for **every** reviewed screenshot — across any domain (multiple-choice quizzes, math/logic/visual puzzles, blank or partial coding challenges, debugging/errors, SQL/regex/formulas, diagrams/charts, interview/reading/open-ended questions, forms, and everyday screen tasks), never bailing out with `"No new findings."`.
3. Supports **on-the-go web lookup** (`WebSearch`/`WebFetch`), enabled by default and toggleable second-by-second while running without restarting.
4. Keeps the terminal UI minimal and clean, showing **only** the information relevant to solving what is on screen.

---

## Architecture Overview

Keep the lightweight macOS Swift + Bash + Claude Code CLI (`claude -p`, subscription auth, no API key) architecture, adding one small Python helper (`solver_stream.py`) to handle multimodal `stream-json` input, real-time token streaming, tool-status updates, and silent context extraction.

```
live-review (interactive loop, 2s poll, single-key controls, clean UI)
   │
   ├── writes live toggles -> state/web_enabled (1|0), state/paused (0|1)
   └── invokes review.sh (LIVE_STREAM=1, optional FORCE_REVIEW=1)
          │
          ├── helper screen / winid + screencapture -> state/screen.png
          ├── helper ocr state/screen.png           -> state/current.txt
          ├── dual change gate:
          │     • sensitive text diff (added lines or Jaccard < 95%, ignoring clocks)
          │     • helper vdiff prev.png screen.png  (48×32 grayscale grid, ≥2% cells shifted)
          │     • bypassed when FORCE_REVIEW=1 or first run
          ├── helper prep state/screen.png state/reviewing.jpg 1920
          └── solver_stream.py -> claude -p --safe-mode --strict-mcp-config
                --no-session-persistence --system-prompt ...
                --input-format stream-json --output-format stream-json
                --verbose --include-partial-messages
                [--tools WebSearch,WebFetch --allowedTools WebSearch,WebFetch | --tools ""]
                │
                ├── streams clean answer tokens live to stdout (strips <<<CONTEXT...CONTEXT>>>)
                ├── updates state/status live on WebSearch/WebFetch tool events
                └── persists clean answer to output/feed.log, output/latest.md, output/history.md
                    and silent context updates to output/problem_context.md
```

---

## Component Design

### 1. Fast Capture, Visual Diff & Downscaling (`helper.swift`)

Add two subcommands to `helper.swift` (zero external dependencies, CoreGraphics only):

- **`helper vdiff <imgA> <imgB>`**
  - Renders both images into a `48×32` 8-bit grayscale buffer (`1536` cells, `<5ms`).
  - Skips the top row (`y = 0`, ~3% of screen height) so macOS menu-bar clock ticks and battery icons do not cause false positives.
  - Counts cells where `|lumA - lumB| > 12` (out of 255) and prints the integer percentage (`0–100`) to stdout.
  - Exits non-zero if either image cannot be decoded.
- **`helper prep <src> <dst> [max_dim]`**
  - Downscales `src` proportionally if `max(width, height) > max_dim` (default `1920`).
  - Writes JPEG (quality `0.85`) when `dst` ends with `.jpg`/`.jpeg`, or PNG otherwise.
  - Keeps OCR running on the crisp original `screen.png` while cutting multimodal upload size from ~2–5 MB Retina PNGs to ~100–250 KB JPEGs.

### 2. Sensitive Dual Change Detection (`review.sh`)

Replace the coarse `SIM >= 90` OCR-only gate with a combined text + visual check:

- **Bypass:** Always run when `FORCE_REVIEW=1`, or when no previous snapshot exists (`last_reviewed.txt` missing).
- **Text diff (on Vision OCR lines > 2 chars, ignoring bare clock/time lines like `14:23` or `14:23:05`):**
  - Compute `added_lines = b - a` and Jaccard similarity `SIM = 100 * |a ∩ b| / max(1, |a ∪ b|)`.
  - Trigger if `SIM < 95` **OR** `len(added_lines) >= 2` **OR** any single added line has length `>= 12` (catches a single new question, error line, or prompt on an otherwise static page).
- **Visual diff:**
  - If text didn't trigger and `last_reviewed.png` exists, run `helper vdiff "$STATE/last_reviewed.png" "$SHOT"`.
  - Trigger if `VDIFF >= 2` (at least 2% of non-menubar grid cells shifted luminance by >12). Catches diagrams, math rendered as images, charts, highlighted quiz selections, and visual puzzles.
- **Snapshot hygiene & mid-run responsiveness:**
  - Snapshot `current.txt` and `screen.png` *before* calling Claude; on success, persist those exact snapshots to `last_reviewed.txt` and `last_reviewed.png` (never overwriting with a newer screen that appeared mid-call).
  - Write `$STATE/did_solve` (`1` when a solve ran, `0` when skipped/paused) so `live-review` re-checks in `0.5s` instead of sleeping the full `INTERVAL` if the user already moved to the next question while Claude was answering.

### 3. Universal Always-Solve Engine & Streaming (`solver_stream.py` + `review.sh`)

#### Eliminating Round-Trip & Startup Latency
- Pass `--safe-mode --strict-mcp-config --no-session-persistence` so `claude -p` skips hooks, skills, plugins, `CLAUDE.md`, and MCP startup overhead while preserving subscription auth and built-in tools.
- Pass a compact dedicated `--system-prompt` (replacing the large default coding-agent system prompt — cuts prompt tokens ~3× and removes coding-only bias).
- Send the downscaled `reviewing.jpg` **inline** as a base64 `image` content block via `--input-format stream-json`. Claude sees the screenshot on Turn 1 with **zero `Read` tool round-trip** (~0.7–1.5s TTFT when answering directly).

#### On-the-Go Web Lookup (`$STATE/web_enabled`)
- Stored in `$STATE/web_enabled` (`1` or `0`; default `1` = ON, overrideable by `WEB_SEARCH=0|1` or `--web` / `--no-web`).
- When `web_enabled=1`: invoke `claude` with `--tools WebSearch,WebFetch --allowedTools WebSearch,WebFetch` and instruct it to solve directly when confident and silently call `WebSearch`/`WebFetch` whenever external facts, docs, obscure errors, or verification help.
- When `web_enabled=0`: invoke `claude` with `--tools ""` (zero tool schema overhead, fastest direct solving).
- Evaluated fresh at the start of every `review.sh` cycle, so flipping `w` takes effect on the very next check.

#### Active Solution Guarantee (Every Reviewed Screenshot)
- The system prompt instructs Claude to **always** identify the primary question, challenge, error, task, or implied goal visible in the screenshot and output a concrete, actionable solution:
  - **Multiple-choice / quiz / test / form:** exact answer first + 1-line rationale.
  - **Math / logic / aptitude / visual puzzle:** final answer first + shortest derivation.
  - **Coding challenge:** complete working solution if editor is empty/incomplete; minimal `before -> after` diff when fixing existing code.
  - **Error / stack trace / CLI / config:** exact root cause + copy-paste fix/command.
  - **Diagrams / charts / tables / reading / interview / writing / general content:** direct answer, recommendation, reply, or concrete next step for what is shown.
- **No bailouts:** explicitly forbids replying with `"No new findings."`, `"Nothing to solve."`, or refusing because a screen isn't a coding editor.
- **Clean output rules:**
  - Start immediately with the answer — NO `"Looking at: ..."`, NO greetings, NO `"Here is the solution:"`, NO `"Let me search..."` filler, NO meta-commentary.
  - Only include information strictly relevant to solving what is on screen.
  - Ignore OS chrome, menus, and any `Live Solver` terminal window itself.
- **Silent context memory:** multi-part specs or background constraints can be appended inside `<<<CONTEXT` … `CONTEXT>>>` at the very end; `solver_stream.py` strips this block before it reaches the terminal and saves it to `output/problem_context.md`.

#### Real-Time Stream Filter (`solver_stream.py`)
- Reads NDJSON from `claude` stdout (with automatic plain-text fallback so non-JSON stubs in `test.sh` and error strings work identically).
- On `content_block_start` for `WebSearch`/`WebFetch` (`tool_use` or `server_tool_use`): writes `searching web...` to `$STATE/status` and updates the transient dimmed status line in place (when `LIVE_STREAM=1` and answer text hasn't started yet).
- On `content_block_delta` (`text_delta`): streams tokens live to stdout using a tiny rolling tail buffer (~16 chars) so `<<<CONTEXT` is detected and halted cleanly before a single marker character ever reaches the terminal.
- On completion: writes the clean solution text (without `<<<CONTEXT...CONTEXT>>>`) and extracted context to temp/output files for `review.sh` to persist into `output/feed.log`, `output/latest.md`, `output/history.md`, and `output/problem_context.md`.

### 4. Clean User Interface & Live Controls (`live-review`)

`live-review` owns the terminal directly (no competing `tail -F state/run.log` noise):

- **Header (1 dimmed line on startup & after clear):**
  ```
  Live Solver · screen 2 (LEN) · [w] web  [Space] solve  [p] pause  [c] clear  [q] quit
  ```
- **Main area:** **ONLY** streamed solutions, separated by a thin dimmed timestamp rule (`─── HH:MM:SS ───`) whenever a new solution begins.
  - No `state/run.log` lines (kept on disk only).
  - No `"Looking at: ..."`, no `"No new findings."`, no `"📌 Problem context updated"`, no verbose `"checked · screen unchanged (95% same)"` clutter.
- **Footer (1 in-place dimmed status line via `\r\033[K`):**
  - `● watching · web ON` / `● watching · web OFF`
  - `◌ solving... · web ON` / `◌ searching web... · web ON`
  - `⏸ paused · web ON`
  - `⚠ retrying... · web ON`
  - Cleared cleanly right before tokens stream and restored right below once the answer finishes.
- **Second-by-second single-key controls (interactive TTY via `/dev/tty`, graceful fallback to `sleep` when non-TTY):**
  - `w` — toggle `$STATE/web_enabled` (`1` ↔ `0`) immediately, updating the status line in place (even while a solve is running; takes effect on the next check).
  - `Space` / `Enter` — trigger an immediate forced solve (`FORCE_REVIEW=1`) right now; if pressed mid-solve, queues an immediate re-solve right after.
  - `p` — toggle `$STATE/paused` (`0` ↔ `1`) immediately.
  - `c` — clear terminal viewport, reset `problem_context.md`, `history.md`, `last_reviewed.txt`, and `last_reviewed.png` for a fresh topic.
  - `q` — clean exit (same as `Ctrl+C`).
- **CLI flags (backwards-compatible):**
  - Existing: `-s/--screen`, `-w/--window`, `-l/--list-screens`, `-i/--interval` (default now `2`), `-m/--model`, `-h/--help`.
  - New: `--web` (default), `--no-web` (start with web lookup OFF).

---

## Error Handling & Compatibility

- Failed or empty `claude` calls do **not** advance `last_reviewed.txt`/`last_reviewed.png`, so the screenshot is retried automatically on the next tick. Detailed stdout/stderr errors are written to `state/run.log` while the terminal stays clean (`⚠ retrying...`).
- `review.sh` continues to work standalone (`reviewer` binary / `launchd` / `watch`), writing `output/feed.log`, `output/latest.md`, `output/history.md`, and `output/problem_context.md`.
- `osascript` desktop notifications remain enabled when a solution is produced and disabled when `NO_NOTIFY=1`.

---

## Verification Plan

1. **Automated test suite (`./test.sh`):**
   - `helper vdiff` (identical -> `0`, modified region -> `>0`, menu-bar-only change -> `0`, missing file -> non-zero) and `helper prep` (downscale & JPEG output).
   - Dual change detection: small 1-line new question triggers; visual-only change triggers; identical screen skips; `FORCE_REVIEW=1` bypasses skip.
   - `solver_stream.py` + `review.sh`: `stream-json` live streaming, `<<<CONTEXT` stripping & persistence, `WebSearch` tool-status update, plain-text stub compatibility, dynamic `web_enabled` toggling between runs (`WebSearch,WebFetch` vs `""`).
   - Always-solve prompt assertions (verifies prompt requires solving every screenshot across coding and non-coding challenges and forbids `"No new findings."`).
   - Clean `live-review` UI assertions: no `run.log` leakage, clean `--web`/`--no-web` flags, symlink + SIGTERM cleanup, zero stray background processes.
2. **Real end-to-end verification (real `claude` CLI):**
   - Test against distinct real/synthetic screenshots covering: (a) a non-coding multiple-choice/math challenge, (b) a coding challenge, and (c) a general real desktop capture — verifying every screenshot produces a clean, active, solution-only streamed answer with both web ON and web OFF.
