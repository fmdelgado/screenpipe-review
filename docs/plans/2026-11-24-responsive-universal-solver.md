# Responsive Universal Screen Solver Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `screenpipe-review` fast, responsive, and clean — solving any challenge/question/task visible on screen on every reviewed screenshot, with live-streamed output and second-by-second on-the-go web lookup toggling.

**Architecture:** Extend `helper.swift` with fast CoreGraphics visual diff (`vdiff`) and Retina downscaling (`prep`). Add a small Python stream runner (`solver_stream.py`) that sends screenshots inline via `--input-format stream-json`, streams clean answers token-by-token from `--output-format stream-json`, updates live web-search status, and strips `<<<CONTEXT...CONTEXT>>>` silently. Update `review.sh` for dual text+visual change detection, dynamic `$STATE/web_enabled` lookup, and an always-solve universal prompt, and simplify `live-review` into a clean solution-only interface with 2s polling and instant single-key controls.

**Tech Stack:** Swift (`CoreGraphics`, `AppKit`, `Vision`), Python 3 (stdlib only), Bash (macOS `/bin/bash` 3.2 compatible), macOS `screencapture`, Claude Code CLI (`claude -p`).

---

### Task 1: Fast Visual Diff (`vdiff`) & Image Downscaling (`prep`) in `helper.swift`

**Files:**
- Modify: `test.sh`
- Modify: `helper.swift`

**Step 1: Write failing tests in `test.sh`**
Add tests under a new `=== Task 4: helper vdiff & prep ===` section (preserving existing Task 1–3 coverage):
- Generate synthetic PNGs via Python/PIL or minimal raw PNG writer (stdlib `zlib`/`struct` so zero external Python packages needed):
  - `img_a.png` (200×200 solid white) and `img_a_copy.png` (identical) -> `helper vdiff` outputs `0`.
  - `img_menubar.png` (top 3px strip black, rest white — simulating menu-bar clock tick) vs `img_a.png` -> `helper vdiff` outputs `0`.
  - `img_box.png` (50×50 black square in center, ~6% of area) vs `img_a.png` -> `helper vdiff` outputs an integer `>= 2`.
  - Missing file -> `helper vdiff` exits non-zero.
  - `img_big.png` (2400×1200) -> `helper prep img_big.png out.jpg 1200` exits `0`, produces non-empty JPEG whose dimensions are `1200×600` (verified with `sips -g pixelWidth -g pixelHeight`).

**Step 2: Run `./test.sh` and verify RED**
Run: `./test.sh`
Expected: FAIL because `helper` does not recognize `vdiff` or `prep`.

**Step 3: Implement `vdiff` and `prep` in `helper.swift` and recompile**
- Add `grayscaleGrid(_ cg: CGImage, width: Int, height: Int) -> [UInt8]?` using `CGColorSpaceCreateDeviceGray()` and `CGContext`.
- Add `case "vdiff":` comparing `bufA` and `bufB` across rows `1..<32` (48×32 grid, skipping top menu-bar row), counting cells with `abs(Int(a) - Int(b)) > 12`, printing integer percentage `0..100`.
- Add `case "prep":` resizing proportionally when `max(width, height) > maxDim` (default `1920`) and writing JPEG (quality `0.85`) for `.jpg`/`.jpeg` or PNG otherwise using `NSBitmapImageRep`.
- Compile: `swiftc -O helper.swift -o helper`.

**Step 4: Run `./test.sh` and verify GREEN**
Run: `./test.sh`
Expected: PASS.

**Step 5: Commit**
```bash
git add helper.swift test.sh
git commit -m "feat(helper): add fast visual diff and image downscaling"
```

---

### Task 2: Multimodal Streaming Runner (`solver_stream.py`) & Universal Always-Solve Engine (`review.sh`)

**Files:**
- Create: `solver_stream.py`
- Modify: `review.sh`
- Modify: `test.sh`

**Step 1: Write failing tests in `test.sh`**
Add tests covering:
- `solver_stream.py` direct tests:
  - Streams `stream-json` `text_delta` chunks cleanly to stdout (`--live-stream 1`), strips `<<<CONTEXT ... CONTEXT>>>` from stdout and `--reply-out`, and persists context to `--context-out`.
  - Updates `--status-file` to `searching web...` when `content_block_start` has `tool_use` `WebSearch`.
  - Handles `is_error: true` JSON result by writing `--err-out`, printing nothing to clean stdout, and exiting non-zero.
  - Handles plain-text stub output seamlessly (extracting `<<<CONTEXT` and writing `--reply-out`).
- `review.sh` tests:
  - Always-solve prompt: captures prompt + system prompt and asserts it handles non-coding challenges (quizzes, math, logic, errors, diagrams, general tasks) and forbids `"No new findings."`.
  - Sensitive text change detection: adding a single 20-char new question line to a 40-line static OCR file triggers a new Claude call (whereas the old `SIM >= 90` gate skipped it!).
  - Visual-only change detection: same OCR text with visually changed `screen.png` (verified via stub or synthetic swap) triggers Claude via `vdiff`.
  - `FORCE_REVIEW=1` bypasses unchanged screen skip.
  - Dynamic web lookup toggle: default (`web_enabled` unset/1) passes `WebSearch,WebFetch` in `--tools`; writing `0` to `$STATE_DIR/web_enabled` causes the very next run to pass `--tools ""` (no `WebSearch`).
  - Clean `feed.log` / `latest.md` output: no `📌 Problem context updated` noise in reply, context still saved to `output/problem_context.md`, `$STATE_DIR/did_solve` set to `1` on solve and `0` on skip.

**Step 2: Run `./test.sh` and verify RED**
Run: `./test.sh`
Expected: FAIL because `solver_stream.py` does not exist and `review.sh` still uses the old code-review prompt and coarse `SIM >= 90` gate.

**Step 3: Implement `solver_stream.py` and update `review.sh`**
- Write `solver_stream.py` (`chmod +x`) with:
  - Inline base64 image + text payload over `--input-format stream-json`.
  - `--safe-mode --strict-mcp-config --no-session-persistence --system-prompt ... --output-format stream-json --verbose --include-partial-messages`.
  - Dynamic `--tools WebSearch,WebFetch --allowedTools WebSearch,WebFetch` vs `--tools ""`.
  - Clean `<<<CONTEXT` rolling-tail suppression while streaming live tokens, live `searching web...` status updates, plain-text fallback, and `SIGINT`/`SIGTERM` child cleanup.
- Update `review.sh` with:
  - Dual text+visual change detection (`SIM < 95` or `>=2` added lines or `>=1` added line `>=12` chars ignoring clocks, or `helper vdiff >= 2`), plus `FORCE_REVIEW=1` bypass and support for visual-only screens with empty OCR text.
  - Downscaling `screen.png` -> `reviewing.jpg` (`1920px`) via `helper prep`.
  - Dynamic `$STATE/web_enabled` check (`WEB_SEARCH` fallback, default `1`).
  - Universal always-solve system prompt + concise user prompt.
  - Clean persistence to `feed.log`, `latest.md`, `history.md`, silent `problem_context.md` update, `$STATE/did_solve` tracking, and `LIVE_STREAM` support.

**Step 4: Run `./test.sh` and verify GREEN**
Run: `./test.sh`
Expected: PASS.

**Step 5: Commit**
```bash
git add solver_stream.py review.sh test.sh
git commit -m "feat(solver): stream universal solutions with dual diff and live web toggle"
```

---

### Task 3: Clean Solution-Only UI & On-the-Go Controls in `live-review`, `watch`, `README.md`

**Files:**
- Modify: `live-review`
- Modify: `watch`
- Modify: `README.md`
- Modify: `test.sh`

**Step 1: Write failing tests in `test.sh`**
Add tests for `live-review`:
- `--help` documents `--web`, `--no-web`, default 2s interval, and interactive keys (`w`, `Space`, `p`, `c`, `q`).
- `--no-web` initializes `$STATE/web_enabled` to `0` and invokes Claude without `WebSearch`.
- `--web` (and default) initializes `$STATE/web_enabled` to `1` and invokes Claude with `WebSearch`.
- Clean UI verification: `live-review` stdout contains the streamed solution text and compact header, and does **NOT** leak `state/run.log` debug lines, `Looking at:`, `No new findings.`, or `Problem context updated`.
- Clean SIGTERM shutdown leaves zero `lock.d` and zero stray processes.

**Step 2: Run `./test.sh` and verify RED**
Run: `./test.sh`
Expected: FAIL because `live-review` lacks `--web`/`--no-web` and still tails `state/run.log`.

**Step 3: Implement `live-review`, `watch`, and `README.md` updates**
- Refactor `live-review`:
  - Default `INTERVAL=2`, add `--web` / `--no-web` flags (default `WEB_SEARCH=1`).
  - Remove background `tail -F feed.log run.log`; run `review.sh` with `LIVE_STREAM=1` so only clean solutions stream to stdout.
  - Render compact 1-line dimmed header and single in-place dimmed status bar (`● watching · web ON`, `◌ solving... · web ON`, `⏸ paused · web OFF`, `⚠ retrying...`).
  - Add interactive single-key controls (Bash 3.2 compatible `read -rsn1 -t 1 </dev/tty` when interactive TTY, graceful `sleep` fallback when non-TTY):
    - `w` toggles `$STATE/web_enabled` immediately (works idle and mid-solve)
    - `Space`/`Enter` forces immediate solve (`FORCE_REVIEW=1`, or queues immediate re-solve if pressed mid-solve)
    - `p` toggles `$STATE/paused`
    - `c` clears viewport and resets saved context/history/last_reviewed
    - `q` exits cleanly
  - Immediately re-check on next loop iteration when `$STATE/did_solve` is `1` (catches screen changes made while Claude was answering with zero wasted sleep!).
- Update `watch` to show only clean `output/feed.log` replies (no `state/run.log` noise).
- Update `README.md` with new usage, flags (`--web`, `--no-web`, 2s default interval), and live key controls.
- Recompile `reviewer` binary if needed (`swiftc -O reviewer.swift -o reviewer`).

**Step 4: Run `./test.sh` and verify GREEN**
Run: `./test.sh`
Expected: PASS (0 failures).

**Step 5: Commit**
```bash
git add live-review watch README.md test.sh
git commit -m "feat(ui): clean solution-only interface with live controls"
```

---

### Task 4: Real End-to-End Live Verification (Real `claude` CLI)

**Files:**
- None modified (isolated temp `STATE_DIR`/`OUT_DIR`)

**Step 1: Verify real `claude` CLI across diverse screenshot types**
Using the real installed `claude` CLI (subscription auth) in an isolated temp directory:
1. **Non-coding math/MCQ challenge screenshot** (generated PNG rendered with a real math/logic multiple-choice question) with **web OFF (`0`)** -> verify fast streamed clean answer with the exact right choice and zero preamble/fluff.
2. **Non-coding factual/current question screenshot** with **web ON (`1`)** -> verify `WebSearch` tool works cleanly and outputs direct solution.
3. **Coding challenge screenshot** (empty/buggy code) -> verify clean direct code solution / minimal fix.
4. **Real live desktop display capture (`SCREEN_TARGET=1`)** -> verify `review.sh` + `live-review` actively suggests a concrete, relevant solution for what's on the real screen with zero `"No new findings."` bailout and clean terminal output.
5. Re-run `./test.sh` as final confirmation.
