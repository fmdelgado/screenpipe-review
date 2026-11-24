# Screen Capture Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a monitor/screen capture mode to `screenpipe-review` so it can screenshot and review one of the connected displays (e.g., built-in Mac screen or external monitor) in addition to the existing `MeowDisplay` window mode.

**Architecture:** Extend `helper.swift` to enumerate active CoreGraphics/AppKit displays (`helper screens`) and resolve flexible display selectors (`1`, `2`, `external`, `builtin`, `main`, `secondary`, or monitor name substring) into the 1-based `screencapture -D` index (`helper screen <target>`). Update `review.sh` and `live-review` to support `SCREEN_TARGET` / `--screen` / `--list-screens` alongside existing `WINDOW_MATCH` mode, and resolve repo paths dynamically (including symlinks) instead of hardcoding `$HOME/screenpipe-review`.

**Tech Stack:** Swift (`CoreGraphics`, `AppKit`, `Vision`), Bash, macOS `screencapture`, Claude Code CLI (`claude`).

---

### Task 1: Display Enumeration & Selector Resolution in `helper.swift`

**Files:**
- Create: `test.sh`
- Modify: `helper.swift`

**Step 1: Compile baseline `helper` and write failing tests in `test.sh`**
- Test `helper screens` outputs active displays formatted as `<idx>: <name> [<tags>] (<w>x<h>)`.
- Test `helper screen 1`, `helper screen builtin`, `helper screen main` resolve cleanly to `<idx>\t<name>`.
- Test multi-monitor selectors (`helper screen 2`, `helper screen external`, `helper screen secondary`, and name substring) when >=2 displays are active.
- Test invalid selectors (`helper screen 99`, `helper screen no-such-display-xyz`) exit non-zero with empty stdout.
- Test existing `helper ocr` still works on a generated image.

**Step 2: Run `./test.sh` and verify RED**
- Expected: FAIL because `helper` only accepts `winid` and `ocr`.

**Step 3: Implement `screens` and `screen <target>` in `helper.swift` and recompile**
- Enumerate active displays via `CGGetActiveDisplayList` + `NSScreen.screens`.
- Implement `screens` listing and `screen <target>` matching (1-based index -> role alias -> localized name substring).
- Compile with `swiftc -O helper.swift -o helper`.

**Step 4: Run `./test.sh` and verify GREEN**
- Expected: PASS.

---

### Task 2: Screen Capture Mode & Dynamic Path Resolution in `review.sh`

**Files:**
- Modify: `test.sh`
- Modify: `review.sh`

**Step 1: Add failing integration tests for `review.sh` in `test.sh`**
- Use isolated temp `STATE_DIR` and `OUT_DIR` plus a stub `CLAUDE_BIN` to test:
  - `SCREEN_TARGET=1` captures display 1 PNG, runs Vision OCR, calls Claude, updates `state/status` and `output/feed.log`.
  - When >=2 displays are active, `SCREEN_TARGET=external` captures display 2 PNG with external monitor dimensions.
  - `SCREEN_TARGET=no-such-display-xyz` writes `screen 'no-such-display-xyz' not found - connect it` to `state/status` and exits `0`.
  - Unset `SCREEN_TARGET` with `WINDOW_MATCH=NoSuchWindowAppXyz` writes `NoSuchWindowAppXyz window not found - open it` to `state/status` and exits `0`.
  - Running `review.sh` from a different working directory resolves `DIR` to the repo directory rather than hardcoded `$HOME/screenpipe-review`.

**Step 2: Run `./test.sh` and verify RED**
- Expected: FAIL because `review.sh` hardcodes `DIR="$HOME/screenpipe-review"` and ignores `SCREEN_TARGET`.

**Step 3: Implement `review.sh` changes**
- Add symlink-aware `resolve_dir` + `SCREENPIPE_DIR`, `STATE_DIR`, `OUT_DIR`, `CLAUDE_BIN` overrides, and auto-build `helper` if missing/older than `helper.swift`.
- Add `SCREEN_TARGET` branch using `helper screen "$SCREEN_TARGET"` and `screencapture -x -D "$DIDX" "$SHOT"`.
- Pass `(cd "$DIR" && ... --add-dir "$STATE")` when invoking `claude` so `Read` can always access `$STATE/reviewing.png` regardless of caller working directory.
- Update review prompt slightly to describe `$CAPTURE_DESC` and ignore OS chrome / `Live code review` terminal output.

**Step 4: Run `./test.sh` and verify GREEN**
- Expected: PASS.

---

### Task 3: CLI Flags & Symlink Support in `live-review`, `watch`, and `reviewer.swift`

**Files:**
- Modify: `test.sh`
- Modify: `live-review`
- Modify: `watch`
- Modify: `reviewer.swift`
- Modify: `README.md`

**Step 1: Add failing CLI tests for `live-review` in `test.sh`**
- Test `live-review --list-screens` and `-l` print displays and exit `0`.
- Test `live-review --help` and `-h` print usage and exit `0`.
- Test unknown flag (`live-review --bogus`) exits `2`.
- Test invoking `live-review` through a symlink in a temp directory resolves `DIR` properly and runs a review cycle with `--screen external` (or `--screen 1`).

**Step 2: Run `./test.sh` and verify RED**
- Expected: FAIL because `live-review` has no flag parser and hardcodes `$HOME/screenpipe-review`.

**Step 3: Implement `live-review`, `watch`, `reviewer.swift`, and `README.md` updates**
- Add `--screen`/`-s`, `--window`/`-w`, `--interval`/`-i`, `--model`/`-m`, `--list-screens`/`-l`, `--help`/`-h` to `live-review`.
- Resolve repo path dynamically in `live-review`, `watch`, and `reviewer.swift`; recompile `reviewer`.
- Document screen mode flags and environment variables in `README.md`.

**Step 4: Run `./test.sh` + End-to-End Real Live Verification**
- Run `./test.sh` and confirm 0 failures.
- Run a real end-to-end check invoking the real `claude` CLI against both connected displays in an isolated temp state/output directory to prove full live functionality.
