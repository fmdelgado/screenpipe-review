#!/bin/bash
set -u

ROOT=$(cd -P "$(dirname "$0")" && pwd)
TMPBASE="${TMPDIR:-/tmp}/screenpipe-review-tests-$$"
mkdir -p "$TMPBASE"
trap 'rm -rf "$TMPBASE"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n' "$1"
  [ -n "${2:-}" ] && printf '     detail: %s\n' "$2"
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$msg"
  else
    fail "$msg" "expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    pass "$msg"
  else
    fail "$msg" "expected output to contain '$needle', got '$haystack'"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if ! printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    pass "$msg"
  else
    fail "$msg" "expected output NOT to contain '$needle', got '$haystack'"
  fi
}

assert_ge() {
  local actual="$1" minval="$2" msg="$3"
  if [ "$actual" -ge "$minval" ] 2>/dev/null; then
    pass "$msg"
  else
    fail "$msg" "expected >= $minval, got '$actual'"
  fi
}

# Pre-generate deterministic synthetic test PNGs (works whether Mac displays are awake or asleep)
swift - "$TMPBASE" <<'SWIFT'
import Foundation
import AppKit

func renderTextPNG(path: String, lines: [String], extraDarkBox: Bool = false) {
    let w = 900, h = 900
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
        .foregroundColor: NSColor.black
    ]
    for (idx, line) in lines.enumerated() {
        let y = CGFloat(h - 40 - idx * 24)
        NSString(string: line).draw(at: NSPoint(x: 30, y: y), withAttributes: attrs)
    }
    if extraDarkBox {
        NSColor.black.setFill()
        NSRect(x: 450, y: 200, width: 320, height: 320).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let base = CommandLine.arguments[1]
let baseLines = (1...25).map { "Background line number \($0) of the document page" }
renderTextPNG(path: "\(base)/page_base.png", lines: baseLines)
renderTextPNG(path: "\(base)/page_small_add.png", lines: baseLines + ["Question: What is the derivative of x^3?"])
renderTextPNG(path: "\(base)/page_visual_change.png", lines: baseLines, extraDarkBox: true)
SWIFT

echo "=== Task 1: helper display listing, resolution & OCR ==="

SCREENS_OUT=$("$ROOT/helper" screens 2>&1)
SCREENS_RC=$?
SCREEN_COUNT=0
if [ "$SCREENS_RC" -eq 0 ]; then
  SCREEN_COUNT=$(printf '%s\n' "$SCREENS_OUT" | grep -c '^[0-9][0-9]*: ')
fi

if [ "$SCREEN_COUNT" -ge 1 ]; then
  assert_eq "$SCREENS_RC" "0" "helper screens exits 0"
  assert_contains "$SCREENS_OUT" "1: " "helper screens lists display 1"

  SCREEN1_OUT=$("$ROOT/helper" screen 1 2>/dev/null)
  assert_eq "$?" "0" "helper screen 1 exits 0"
  assert_eq "${SCREEN1_OUT%%$'\t'*}" "1" "helper screen 1 returns index 1"

  MAIN_OUT=$("$ROOT/helper" screen main 2>/dev/null)
  assert_eq "$?" "0" "helper screen main exits 0"
  assert_eq "$MAIN_OUT" "$SCREEN1_OUT" "helper screen main matches display 1"

  if printf '%s\n' "$SCREENS_OUT" | grep -q '\[builtin'; then
    BUILTIN_OUT=$("$ROOT/helper" screen builtin 2>/dev/null)
    assert_eq "$?" "0" "helper screen builtin exits 0"
    assert_contains "$BUILTIN_OUT" "Built-in" "helper screen builtin resolves built-in display"
  fi

  if [ "$SCREEN_COUNT" -ge 2 ]; then
    SCREEN2_OUT=$("$ROOT/helper" screen 2 2>/dev/null)
    assert_eq "$?" "0" "helper screen 2 exits 0"
    assert_eq "${SCREEN2_OUT%%$'\t'*}" "2" "helper screen 2 returns index 2"

    SEC_OUT=$("$ROOT/helper" screen secondary 2>/dev/null)
    assert_eq "$?" "0" "helper screen secondary exits 0"
    assert_eq "$SEC_OUT" "$SCREEN2_OUT" "helper screen secondary matches display 2"

    if printf '%s\n' "$SCREENS_OUT" | grep -q 'external'; then
      EXT_OUT=$("$ROOT/helper" screen external 2>/dev/null)
      assert_eq "$?" "0" "helper screen external exits 0"
      assert_eq "$EXT_OUT" "$SCREEN2_OUT" "helper screen external resolves external monitor"

      D2_NAME="${SCREEN2_OUT#*$'\t'}"
      SUBSTR=$(printf '%s' "$D2_NAME" | awk '{print tolower($1)}')
      SUB_OUT=$("$ROOT/helper" screen "$SUBSTR" 2>/dev/null)
      assert_eq "$?" "0" "helper screen '$SUBSTR' (name substring) exits 0"
      assert_eq "$SUB_OUT" "$SCREEN2_OUT" "helper screen '$SUBSTR' resolves external monitor"
    fi
  fi
else
  printf '  ℹ️  displays asleep — skipping awake-display enumeration checks\n'
fi

BAD_IDX_OUT=$("$ROOT/helper" screen 99 2>/dev/null)
BAD_IDX_RC=$?
if [ "$BAD_IDX_RC" -ne 0 ] && [ -z "$BAD_IDX_OUT" ]; then
  pass "helper screen 99 fails cleanly with empty stdout"
else
  fail "helper screen 99 should fail cleanly" "rc=$BAD_IDX_RC out='$BAD_IDX_OUT'"
fi

BAD_NAME_OUT=$("$ROOT/helper" screen nonexistent-monitor-xyz 2>/dev/null)
BAD_NAME_RC=$?
if [ "$BAD_NAME_RC" -ne 0 ] && [ -z "$BAD_NAME_OUT" ]; then
  pass "helper screen nonexistent-monitor-xyz fails cleanly with empty stdout"
else
  fail "helper screen nonexistent-monitor-xyz should fail cleanly" "rc=$BAD_NAME_RC out='$BAD_NAME_OUT'"
fi

"$ROOT/helper" bogus-cmd >/dev/null 2>&1
assert_eq "$?" "2" "helper unknown subcommand exits 2"

# Regression check: Vision OCR works deterministically on rendered text PNG
OCR_OUT=$("$ROOT/helper" ocr "$TMPBASE/page_small_add.png" 2>/dev/null)
assert_eq "$?" "0" "helper ocr exits 0 on text PNG"
assert_contains "$OCR_OUT" "derivative" "helper ocr extracts text from image"

echo
echo "=== Task 2: review.sh capture modes, path resolution & error handling ==="

STUB_CLAUDE="$TMPBASE/stub-claude"
cat > "$STUB_CLAUDE" <<'EOF'
#!/bin/bash
cat > "${STUB_PROMPT_CAPTURE:?}"
printf '%s\n' "$*" > "${STUB_ARGS_CAPTURE:?}"
echo "Answer: 42"
EOF
chmod +x "$STUB_CLAUDE"

# 2a. Missing screen writes helpful status and exits 0 (invoked from $TMPBASE to verify DIR resolution)
T2_MISS_STATE="$TMPBASE/t2_miss_state"
T2_MISS_OUT="$TMPBASE/t2_miss_out"
(
  cd "$TMPBASE" &&
  STATE_DIR="$T2_MISS_STATE" OUT_DIR="$T2_MISS_OUT" SCREEN_TARGET="no-such-display-xyz" \
  CLAUDE_BIN="$STUB_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
)
assert_eq "$?" "0" "review.sh exits 0 when target screen is missing"
assert_eq "$(cat "$T2_MISS_STATE/status" 2>/dev/null)" "screen 'no-such-display-xyz' not found - connect it" \
  "review.sh writes missing-screen status"

# 2b. Default window mode still works when SCREEN_TARGET is unset
T2_WIN_STATE="$TMPBASE/t2_win_state"
T2_WIN_OUT="$TMPBASE/t2_win_out"
(
  cd "$TMPBASE" &&
  STATE_DIR="$T2_WIN_STATE" OUT_DIR="$T2_WIN_OUT" WINDOW_MATCH="NoSuchWindowAppXyz" \
  CLAUDE_BIN="$STUB_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
)
assert_eq "$?" "0" "review.sh exits 0 when target window is missing"
assert_eq "$(cat "$T2_WIN_STATE/status" 2>/dev/null)" "NoSuchWindowAppXyz window not found - open it" \
  "review.sh preserves window-not-found status when SCREEN_TARGET is unset"

# 2c. Deterministic capture + OCR + Claude stub cycle from external cwd
T2_S1_STATE="$TMPBASE/t2_s1_state"
T2_S1_OUT="$TMPBASE/t2_s1_out"
T2_S1_PROMPT="$TMPBASE/t2_s1_prompt.txt"
T2_S1_ARGS="$TMPBASE/t2_s1_args.txt"
(
  cd "$TMPBASE" &&
  STATE_DIR="$T2_S1_STATE" OUT_DIR="$T2_S1_OUT" \
  CAPTURE_IMAGE="$TMPBASE/page_base.png" CAPTURE_DESC_OVERRIDE="screen 1 (Test Display)" \
  CLAUDE_BIN="$STUB_CLAUDE" STUB_PROMPT_CAPTURE="$T2_S1_PROMPT" STUB_ARGS_CAPTURE="$T2_S1_ARGS" \
  NO_NOTIFY=1 "$ROOT/review.sh"
)
assert_eq "$?" "0" "review.sh succeeds on capture cycle"
if [ -s "$T2_S1_STATE/screen.png" ]; then
  pass "review.sh writes non-empty screen.png"
else
  fail "review.sh failed to write screen.png"
fi
assert_eq "$(cat "$T2_S1_STATE/status" 2>/dev/null)" "watching" \
  "review.sh sets clean watching status after solve"
assert_contains "$(cat "$T2_S1_PROMPT" 2>/dev/null)" "Watching: screen 1" \
  "review.sh prompt identifies watched screen"
assert_contains "$(cat "$T2_S1_ARGS" 2>/dev/null)" "--add-dir $T2_S1_STATE" \
  "review.sh grants claude access to STATE_DIR"
assert_contains "$(cat "$T2_S1_OUT/feed.log" 2>/dev/null)" "Answer: 42" \
  "review.sh appends clean solution to feed.log"

# 2d. Live hardware display capture when displays are awake
if [ "$SCREEN_COUNT" -ge 1 ]; then
  T2_LIVE1_STATE="$TMPBASE/t2_live1_state"
  T2_LIVE1_OUT="$TMPBASE/t2_live1_out"
  T2_LIVE1_PROMPT="$TMPBASE/t2_live1_prompt.txt"
  T2_LIVE1_ARGS="$TMPBASE/t2_live1_args.txt"
  (
    cd "$TMPBASE" &&
    STATE_DIR="$T2_LIVE1_STATE" OUT_DIR="$T2_LIVE1_OUT" SCREEN_TARGET="1" \
    CLAUDE_BIN="$STUB_CLAUDE" STUB_PROMPT_CAPTURE="$T2_LIVE1_PROMPT" STUB_ARGS_CAPTURE="$T2_LIVE1_ARGS" \
    NO_NOTIFY=1 "$ROOT/review.sh"
  )
  assert_eq "$?" "0" "review.sh succeeds with live SCREEN_TARGET=1"
  assert_contains "$(cat "$T2_LIVE1_PROMPT" 2>/dev/null)" "Watching: screen 1" \
    "review.sh live prompt identifies screen 1"

  if [ "$SCREEN_COUNT" -ge 2 ] && printf '%s\n' "$SCREENS_OUT" | grep -q 'external'; then
    T2_S2_STATE="$TMPBASE/t2_s2_state"
    T2_S2_OUT="$TMPBASE/t2_s2_out"
    T2_S2_PROMPT="$TMPBASE/t2_s2_prompt.txt"
    T2_S2_ARGS="$TMPBASE/t2_s2_args.txt"
    (
      cd "$TMPBASE" &&
      STATE_DIR="$T2_S2_STATE" OUT_DIR="$T2_S2_OUT" SCREEN_TARGET="external" \
      CLAUDE_BIN="$STUB_CLAUDE" STUB_PROMPT_CAPTURE="$T2_S2_PROMPT" STUB_ARGS_CAPTURE="$T2_S2_ARGS" \
      NO_NOTIFY=1 "$ROOT/review.sh"
    )
    assert_eq "$?" "0" "review.sh succeeds with live SCREEN_TARGET=external"
    if [ -s "$T2_LIVE1_STATE/screen.png" ] && [ -s "$T2_S2_STATE/screen.png" ] && \
       ! cmp -s "$T2_LIVE1_STATE/screen.png" "$T2_S2_STATE/screen.png"; then
      pass "screen 1 and external monitor screenshots are distinct images"
    else
      fail "screen 1 and external monitor screenshots were missing or identical"
    fi
    assert_contains "$(cat "$T2_S2_PROMPT" 2>/dev/null)" "Watching: screen 2" \
      "review.sh prompt identifies external monitor as screen 2"
  fi
fi

# 2e. Compiled ./reviewer binary + silent context extraction + solution persistence
FINDING_CLAUDE="$TMPBASE/finding-claude"
cat > "$FINDING_CLAUDE" <<'EOF'
#!/bin/bash
cat >/dev/null
cat <<'REPLY'
solution.py:12 — off-by-one violates N-element bound: `range(n + 1)` -> `range(n)`
<<<CONTEXT
- Input array has N integers; return sum of all N elements.
CONTEXT>>>
REPLY
EOF
chmod +x "$FINDING_CLAUDE"

T2_CTX_STATE="$TMPBASE/t2_ctx_state"
T2_CTX_OUT="$TMPBASE/t2_ctx_out"
STATE_DIR="$T2_CTX_STATE" OUT_DIR="$T2_CTX_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$FINDING_CLAUDE" NO_NOTIFY=1 "$ROOT/reviewer"
assert_eq "$?" "0" "compiled reviewer binary runs review.sh cleanly"
assert_contains "$(cat "$T2_CTX_OUT/problem_context.md" 2>/dev/null)" "Input array has N integers" \
  "review.sh saves extracted problem context"
assert_contains "$(cat "$T2_CTX_OUT/latest.md" 2>/dev/null)" "off-by-one" \
  "review.sh writes solution to latest.md"

# 2f. Non-zero claude exit surfaces error detail in run.log and marks retrying...
FAIL_CLAUDE="$TMPBASE/fail-claude"
cat > "$FAIL_CLAUDE" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "You've hit your spend limit"
exit 1
EOF
chmod +x "$FAIL_CLAUDE"

T2_ERR_STATE="$TMPBASE/t2_err_state"
T2_ERR_OUT="$TMPBASE/t2_err_out"
STATE_DIR="$T2_ERR_STATE" OUT_DIR="$T2_ERR_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$FAIL_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T2_ERR_STATE/status" 2>/dev/null)" "retrying..." \
  "review.sh marks status as retrying... on claude error"
assert_contains "$(cat "$T2_ERR_STATE/run.log" 2>/dev/null)" "hit your spend limit" \
  "review.sh logs claude error detail to run.log"
if [ ! -f "$T2_ERR_STATE/last_reviewed.txt" ]; then
  pass "review.sh does not advance last_reviewed on failed claude call"
else
  fail "review.sh should not advance last_reviewed on error"
fi

echo
echo "=== Task 3: live-review CLI flags, symlink resolution & lifecycle ==="

run_with_timeout() {
  local secs="$1"; shift
  python3 - "$secs" "$@" <<'PY'
import subprocess, sys
timeout = float(sys.argv[1])
try:
    p = subprocess.run(sys.argv[2:], capture_output=True, text=True, timeout=timeout)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    sys.stderr.write("TIMEOUT\n")
    sys.exit(124)
PY
}

mkdir -p "$TMPBASE/bin"
ln -sf "$ROOT/live-review" "$TMPBASE/bin/live-review"

# 3a. --list-screens via symlink from outside repo (when displays awake)
if [ "$SCREEN_COUNT" -ge 1 ]; then
  LS_OUT=$(cd "$TMPBASE" && run_with_timeout 5 "$TMPBASE/bin/live-review" --list-screens 2>&1)
  LS_RC=$?
  assert_eq "$LS_RC" "0" "live-review --list-screens exits 0 via symlink"
  assert_contains "$LS_OUT" "1: " "live-review --list-screens prints display list"
fi

# 3b. -h / --help
HELP_OUT=$(run_with_timeout 5 "$TMPBASE/bin/live-review" --help 2>&1)
HELP_RC=$?
assert_eq "$HELP_RC" "0" "live-review --help exits 0"
assert_contains "$HELP_OUT" "--screen" "live-review --help documents --screen"
assert_contains "$HELP_OUT" "--list-screens" "live-review --help documents --list-screens"

# 3c. Invalid flag & missing flag argument exit 2
run_with_timeout 5 "$TMPBASE/bin/live-review" --bogus-flag >/dev/null 2>&1
assert_eq "$?" "2" "live-review unknown flag exits 2"

run_with_timeout 5 "$TMPBASE/bin/live-review" --screen >/dev/null 2>&1
assert_eq "$?" "2" "live-review --screen without value exits 2"

# 3d. End-to-end foreground loop via symlink + clean SIGTERM shutdown
T3_STATE="$TMPBASE/t3_state"
T3_OUT="$TMPBASE/t3_out"
T3_PROMPT="$TMPBASE/t3_prompt.txt"
T3_ARGS="$TMPBASE/t3_args.txt"
T3_STDOUT="$TMPBASE/t3_stdout.log"

(
  cd "$TMPBASE" &&
  STATE_DIR="$T3_STATE" OUT_DIR="$T3_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$STUB_CLAUDE" STUB_PROMPT_CAPTURE="$T3_PROMPT" STUB_ARGS_CAPTURE="$T3_ARGS" \
  NO_NOTIFY=1 TERM=dumb exec "$TMPBASE/bin/live-review" --interval 30 >"$T3_STDOUT" 2>&1
) &
LR_PID=$!

for _ in $(seq 1 40); do
  [ -f "$T3_OUT/latest.md" ] && grep -q "Answer: 42" "$T3_OUT/latest.md" 2>/dev/null && break
  sleep 0.25
done
sleep 0.2
kill -TERM "$LR_PID" 2>/dev/null || true
wait "$LR_PID" 2>/dev/null || true

assert_contains "$(cat "$T3_STDOUT" 2>/dev/null)" "Live Solver" \
  "live-review shows compact Live Solver header"
assert_eq "$(cat "$T3_STATE/status" 2>/dev/null)" "watching" \
  "live-review completes solve cycle and returns to watching"
if [ ! -d "$T3_STATE/lock.d" ]; then
  pass "live-review cleans up lock.d on SIGTERM"
else
  fail "live-review left stale lock.d after SIGTERM"
fi

# 3e. Live monitor foreground loop when external display is awake
if [ "$SCREEN_COUNT" -ge 2 ] && printf '%s\n' "$SCREENS_OUT" | grep -q 'external'; then
  T3E_STATE="$TMPBASE/t3e_state"
  T3E_OUT="$TMPBASE/t3e_out"
  T3E_PROMPT="$TMPBASE/t3e_prompt.txt"
  T3E_ARGS="$TMPBASE/t3e_args.txt"
  T3E_STDOUT="$TMPBASE/t3e_stdout.log"

  (
    cd "$TMPBASE" &&
    STATE_DIR="$T3E_STATE" OUT_DIR="$T3E_OUT" \
    CLAUDE_BIN="$STUB_CLAUDE" STUB_PROMPT_CAPTURE="$T3E_PROMPT" STUB_ARGS_CAPTURE="$T3E_ARGS" \
    NO_NOTIFY=1 TERM=dumb exec "$TMPBASE/bin/live-review" --screen external --interval 30 >"$T3E_STDOUT" 2>&1
  ) &
  LR_EXT_PID=$!

  for _ in $(seq 1 40); do
    [ -f "$T3E_OUT/latest.md" ] && grep -q "Answer: 42" "$T3E_OUT/latest.md" 2>/dev/null && break
    sleep 0.25
  done
  sleep 0.2
  kill -TERM "$LR_EXT_PID" 2>/dev/null || true
  wait "$LR_EXT_PID" 2>/dev/null || true

  assert_contains "$(cat "$T3E_STDOUT" 2>/dev/null)" "watching screen 2" \
    "live-review --screen external banner shows screen 2"
  assert_eq "$(cat "$T3E_STATE/status" 2>/dev/null)" "watching" \
    "live-review --screen external runs solve cycle on external monitor"
fi

sleep 0.2
STRAY=$(pgrep -fl "$TMPBASE" 2>/dev/null || true)
assert_eq "$STRAY" "" "no stray background processes left after live-review shutdown"

echo
echo "=== Task 4: helper vdiff & prep ==="

python3 - "$TMPBASE" <<'PY'
import os, struct, sys, zlib

def write_png(path, w, h, fn):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            r, g, b = fn(x, y)
            raw.extend((r, g, b))
    def chunk(tag, data):
        return struct.pack("!I", len(data)) + tag + data + struct.pack("!I", zlib.crc32(tag + data) & 0xffffffff)
    ihdr = struct.pack("!IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 1)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

base = sys.argv[1]
write_png(os.path.join(base, "v_white.png"), 200, 200, lambda x, y: (240, 240, 240))
write_png(os.path.join(base, "v_white2.png"), 200, 200, lambda x, y: (240, 240, 240))
write_png(os.path.join(base, "v_menubar.png"), 200, 200, lambda x, y: (10, 10, 10) if y < 4 else (240, 240, 240))
write_png(os.path.join(base, "v_box.png"), 200, 200, lambda x, y: (20, 20, 20) if 70 <= x < 130 and 70 <= y < 130 else (240, 240, 240))
write_png(os.path.join(base, "v_big.png"), 2400, 1200, lambda x, y: (50, 100, 150))
PY

VD_SAME=$("$ROOT/helper" vdiff "$TMPBASE/v_white.png" "$TMPBASE/v_white2.png" 2>/dev/null)
assert_eq "$?" "0" "helper vdiff exits 0 on identical images"
assert_eq "$VD_SAME" "0" "helper vdiff returns 0 for identical images"

VD_MENU=$("$ROOT/helper" vdiff "$TMPBASE/v_white.png" "$TMPBASE/v_menubar.png" 2>/dev/null)
assert_eq "$?" "0" "helper vdiff exits 0 on menu-bar change"
assert_eq "$VD_MENU" "0" "helper vdiff ignores top menu-bar strip changes"

VD_BOX=$("$ROOT/helper" vdiff "$TMPBASE/v_white.png" "$TMPBASE/v_box.png" 2>/dev/null)
assert_eq "$?" "0" "helper vdiff exits 0 on modified region"
assert_ge "$VD_BOX" "4" "helper vdiff detects visual region change (>=4%)"

"$ROOT/helper" vdiff "$TMPBASE/v_white.png" "$TMPBASE/no_such_file.png" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
  pass "helper vdiff exits non-zero on missing image"
else
  fail "helper vdiff should fail on missing image"
fi

PREP_OUT="$TMPBASE/v_prepped.jpg"
"$ROOT/helper" prep "$TMPBASE/v_big.png" "$PREP_OUT" 1200 2>/dev/null
assert_eq "$?" "0" "helper prep exits 0 when downscaling to JPEG"
if [ -s "$PREP_OUT" ]; then
  pass "helper prep writes non-empty JPEG"
else
  fail "helper prep failed to write output JPEG"
fi
PREP_W=$(sips -g pixelWidth "$PREP_OUT" 2>/dev/null | awk '/pixelWidth/{print $2}')
PREP_H=$(sips -g pixelHeight "$PREP_OUT" 2>/dev/null | awk '/pixelHeight/{print $2}')
assert_eq "${PREP_W}x${PREP_H}" "1200x600" "helper prep preserves aspect ratio when downscaling 2400x1200 -> 1200x600"

PREP_SMALL="$TMPBASE/v_small.jpg"
"$ROOT/helper" prep "$TMPBASE/v_white.png" "$PREP_SMALL" 1920 2>/dev/null
assert_eq "$?" "0" "helper prep exits 0 when image is already smaller than max_dim"
SMALL_W=$(sips -g pixelWidth "$PREP_SMALL" 2>/dev/null | awk '/pixelWidth/{print $2}')
SMALL_H=$(sips -g pixelHeight "$PREP_SMALL" 2>/dev/null | awk '/pixelHeight/{print $2}')
assert_eq "${SMALL_W}x${SMALL_H}" "200x200" "helper prep does not upscale smaller images"

echo
echo "=== Task 5: solver_stream.py & universal review.sh engine ==="

# 5a. solver_stream.py handles stream-json live deltas, WebSearch status, and strips <<<CONTEXT
STREAM_CLAUDE="$TMPBASE/stream-claude"
cat > "$STREAM_CLAUDE" <<'EOF'
#!/bin/bash
cat > "${STUB_STDIN_CAPTURE:?}"
printf '%s\n' "$*" > "${STUB_ARGS_CAPTURE:?}"
cat <<'JSON'
{"type":"system","subtype":"init","tools":["WebSearch","WebFetch"]}
{"type":"stream_event","event":{"type":"message_start","message":{"role":"assistant"}}}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"WebSearch"}}}
{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer: "}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"B (42)\n"}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Because 6 * 7 = 42.\n<<<"}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"CONTEXT\n- Quiz Q1: 6*7\nCONTEXT>>>"}}}
{"type":"result","subtype":"success","is_error":false,"result":"Answer: B (42)\nBecause 6 * 7 = 42.\n<<<CONTEXT\n- Quiz Q1: 6*7\nCONTEXT>>>"}
JSON
EOF
chmod +x "$STREAM_CLAUDE"

T5_DIR="$TMPBASE/t5_stream"
mkdir -p "$T5_DIR"
printf 'You are a solver.' > "$T5_DIR/sys.txt"
printf 'Solve this.' > "$T5_DIR/usr.txt"
T5_LIVE=$(STUB_STDIN_CAPTURE="$T5_DIR/stdin.json" STUB_ARGS_CAPTURE="$T5_DIR/args.txt" \
  python3 -I "$ROOT/solver_stream.py" \
    --claude "$STREAM_CLAUDE" \
    --model claude-sonnet-5-5 \
    --image "$TMPBASE/v_white.png" \
    --system-prompt-file "$T5_DIR/sys.txt" \
    --prompt-file "$T5_DIR/usr.txt" \
    --web 1 \
    --status-file "$T5_DIR/status" \
    --reply-out "$T5_DIR/reply.txt" \
    --context-out "$T5_DIR/ctx.txt" \
    --err-out "$T5_DIR/err.txt" \
    --live-stream 1 \
    --divider-time "12:34:56" 2>/dev/null)
assert_eq "$?" "0" "solver_stream.py exits 0 on valid stream-json"
assert_contains "$T5_LIVE" "Answer: B (42)" "solver_stream.py streams clean answer live"
assert_not_contains "$T5_LIVE" "<<<CONTEXT" "solver_stream.py strips <<<CONTEXT from live stdout"
assert_not_contains "$T5_LIVE" "Quiz Q1" "solver_stream.py hides context body from live stdout"
assert_contains "$T5_LIVE" "searching web..." "solver_stream.py shows web search status during WebSearch tool_use"
assert_contains "$(cat "$T5_DIR/reply.txt" 2>/dev/null)" "Because 6 * 7 = 42." "solver_stream.py writes clean reply file"
assert_not_contains "$(cat "$T5_DIR/reply.txt" 2>/dev/null)" "<<<CONTEXT" "solver_stream.py strips context from reply file"
assert_contains "$(cat "$T5_DIR/ctx.txt" 2>/dev/null)" "Quiz Q1: 6*7" "solver_stream.py extracts context to context file"
assert_contains "$(cat "$T5_DIR/stdin.json" 2>/dev/null)" '"type": "image"' "solver_stream.py inlines screenshot as stream-json image block"
assert_contains "$(cat "$T5_DIR/args.txt" 2>/dev/null)" "WebSearch,WebFetch" "solver_stream.py enables WebSearch,WebFetch when --web 1"
assert_contains "$(cat "$T5_DIR/args.txt" 2>/dev/null)" "--safe-mode" "solver_stream.py passes --safe-mode for fast startup"

# 5b. solver_stream.py --clear-on-start clears terminal+scrollback and prints only header + present solution
T5C_LIVE=$(STUB_STDIN_CAPTURE="$T5_DIR/stdin_c.json" STUB_ARGS_CAPTURE="$T5_DIR/args_c.txt" \
  python3 -I "$ROOT/solver_stream.py" \
    --claude "$STREAM_CLAUDE" \
    --model claude-sonnet-5-5 \
    --system-prompt-file "$T5_DIR/sys.txt" \
    --prompt-file "$T5_DIR/usr.txt" \
    --web 1 \
    --status-file "$T5_DIR/status_c" \
    --reply-out "$T5_DIR/reply_c.txt" \
    --context-out "$T5_DIR/ctx_c.txt" \
    --err-out "$T5_DIR/err_c.txt" \
    --live-stream 1 \
    --clear-on-start 1 \
    --header-text "Live Solver · Test" \
    --divider-time "12:34:56" 2>/dev/null)
assert_contains "$T5C_LIVE" $'\033[H\033[2J\033[3J' "solver_stream.py --clear-on-start wipes terminal & scrollback before new answer"
assert_contains "$T5C_LIVE" "Live Solver · Test" "solver_stream.py --clear-on-start prints compact header"
assert_contains "$T5C_LIVE" "Answer: B (42)" "solver_stream.py --clear-on-start streams present solution"
assert_not_contains "$T5C_LIVE" "─── 12:34:56 ───" "solver_stream.py --clear-on-start omits redundant timestamp divider"

# 5c. solver_stream.py handles JSON is_error cleanly without polluting stdout
ERR_JSON_CLAUDE="$TMPBASE/err-json-claude"
cat > "$ERR_JSON_CLAUDE" <<'EOF'
#!/bin/bash
cat >/dev/null
echo '{"type":"result","subtype":"error","is_error":true,"result":"Rate limit exceeded"}'
EOF
chmod +x "$ERR_JSON_CLAUDE"

T5E_DIR="$TMPBASE/t5_err"
mkdir -p "$T5E_DIR"
T5E_LIVE=$(python3 -I "$ROOT/solver_stream.py" \
  --claude "$ERR_JSON_CLAUDE" \
  --model claude-sonnet-5-5 \
  --system-prompt-file "$T5_DIR/sys.txt" \
  --prompt-file "$T5_DIR/usr.txt" \
  --web 0 \
  --status-file "$T5E_DIR/status" \
  --reply-out "$T5E_DIR/reply.txt" \
  --context-out "$T5E_DIR/ctx.txt" \
  --err-out "$T5E_DIR/err.txt" \
  --live-stream 1 2>/dev/null)
if [ "$?" -ne 0 ]; then
  pass "solver_stream.py exits non-zero on JSON is_error"
else
  fail "solver_stream.py should exit non-zero on JSON is_error"
fi
assert_eq "$T5E_LIVE" "" "solver_stream.py keeps live stdout clean on JSON error"
assert_contains "$(cat "$T5E_DIR/err.txt" 2>/dev/null)" "Rate limit exceeded" "solver_stream.py captures JSON error detail"

# 5c. review.sh universal always-solve prompt, sensitive small-line trigger, visual trigger, FORCE_REVIEW, dynamic web toggle
T5R_STATE="$TMPBASE/t5r_state"
T5R_OUT="$TMPBASE/t5r_out"
T5R_COUNT="$TMPBASE/t5r_calls"
echo 0 > "$T5R_COUNT"
T5R_CLAUDE="$TMPBASE/t5r-claude"
cat > "$T5R_CLAUDE" <<EOF
#!/bin/bash
cat > "$TMPBASE/t5r_last_stdin.json"
printf '%s\n' "\$*" > "$TMPBASE/t5r_last_args.txt"
c=\$(cat "$T5R_COUNT")
echo \$((c + 1)) > "$T5R_COUNT"
cat <<'REPLY'
Answer: 3x^2
Power rule: d/dx(x^n) = n*x^(n-1).
<<<CONTEXT
- Calculus quiz active
CONTEXT>>>
REPLY
EOF
chmod +x "$T5R_CLAUDE"

# Run 1: initial capture (web ON by default)
STATE_DIR="$T5R_STATE" OUT_DIR="$T5R_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$T5R_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T5R_COUNT")" "1" "review.sh solves initial capture"
assert_eq "$(cat "$T5R_STATE/did_solve" 2>/dev/null)" "1" "review.sh marks did_solve=1 after solve"
assert_contains "$(cat "$TMPBASE/t5r_last_args.txt" 2>/dev/null)" "WebSearch,WebFetch" "review.sh enables WebSearch by default"
assert_contains "$(cat "$TMPBASE/t5r_last_args.txt" 2>/dev/null)" "Never reply with" "review.sh system prompt forbids bailout replies"
assert_contains "$(cat "$TMPBASE/t5r_last_args.txt" 2>/dev/null)" "Multiple choice" "review.sh system prompt handles non-coding challenges"
assert_contains "$(cat "$TMPBASE/t5r_last_args.txt" 2>/dev/null)" "NEVER recap, list, or repeat previous questions" "review.sh system prompt forbids repeating previous questions"
assert_not_contains "$(cat "$TMPBASE/t5r_last_stdin.json" 2>/dev/null)" "RECENT SOLUTIONS" "review.sh omits long prior-solution history from prompt"
assert_contains "$(cat "$T5R_OUT/latest.md" 2>/dev/null)" "Answer: 3x^2" "review.sh saves clean solution to latest.md"
assert_not_contains "$(cat "$T5R_OUT/feed.log" 2>/dev/null)" "Problem context updated" "review.sh keeps feed.log free of context-updated noise"
assert_contains "$(cat "$T5R_OUT/problem_context.md" 2>/dev/null)" "Calculus quiz active" "review.sh silently saves problem_context.md"

# Run 2: identical screenshot -> skipped (did_solve=0)
STATE_DIR="$T5R_STATE" OUT_DIR="$T5R_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$T5R_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T5R_COUNT")" "1" "review.sh skips unchanged screenshot"
assert_eq "$(cat "$T5R_STATE/did_solve" 2>/dev/null)" "0" "review.sh marks did_solve=0 when skipped"

# Run 3: small 1-line question added to 25-line static page (sim ~96% > old 90%!) -> MUST trigger!
echo "0" > "$T5R_STATE/web_enabled"
STATE_DIR="$T5R_STATE" OUT_DIR="$T5R_OUT" CAPTURE_IMAGE="$TMPBASE/page_small_add.png" \
  CLAUDE_BIN="$T5R_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T5R_COUNT")" "2" "review.sh triggers on single new question line on a large static page"
assert_not_contains "$(cat "$TMPBASE/t5r_last_args.txt" 2>/dev/null)" "WebSearch" "review.sh immediately disables WebSearch when state/web_enabled=0"

# Run 4: visual-only change (identical OCR text, black diagram box added) -> MUST trigger via vdiff!
echo "1" > "$T5R_STATE/web_enabled"
STATE_DIR="$T5R_STATE" OUT_DIR="$T5R_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$T5R_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
STATE_DIR="$T5R_STATE" OUT_DIR="$T5R_OUT" CAPTURE_IMAGE="$TMPBASE/page_visual_change.png" \
  CLAUDE_BIN="$T5R_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T5R_COUNT")" "4" "review.sh triggers on visual-only change with identical OCR text"
assert_contains "$(cat "$TMPBASE/t5r_last_args.txt" 2>/dev/null)" "WebSearch,WebFetch" "review.sh immediately re-enables WebSearch when state/web_enabled=1"

# Run 5: FORCE_REVIEW=1 bypasses unchanged gate
STATE_DIR="$T5R_STATE" OUT_DIR="$T5R_OUT" CAPTURE_IMAGE="$TMPBASE/page_visual_change.png" \
  FORCE_REVIEW=1 CLAUDE_BIN="$T5R_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T5R_COUNT")" "5" "FORCE_REVIEW=1 triggers solve even on identical screenshot"

echo
echo "=== Task 6: live-review clean UI & live single-key controls ==="

# 6a. --help documents --web, --no-web, 2s default interval, and live keys
HELP6_OUT=$(run_with_timeout 5 "$TMPBASE/bin/live-review" --help 2>&1)
assert_contains "$HELP6_OUT" "--web" "live-review --help documents --web"
assert_contains "$HELP6_OUT" "--no-web" "live-review --help documents --no-web"
assert_contains "$HELP6_OUT" "default: 2" "live-review --help documents 2s default interval"
assert_contains "$HELP6_OUT" "[w]" "live-review --help documents [w] live web toggle"

# 6b. Clean UI with --no-web: streams only solution content, hides run.log & <<<CONTEXT, sets web_enabled=0
T6_STATE="$TMPBASE/t6_state"
T6_OUT="$TMPBASE/t6_out"
T6_STDOUT="$TMPBASE/t6_stdout.log"
T6_ARGS="$TMPBASE/t6_args.txt"
T6_CLAUDE="$TMPBASE/t6-claude"
cat > "$T6_CLAUDE" <<EOF
#!/bin/bash
cat >/dev/null
printf '%s\n' "\$*" > "$T6_ARGS"
cat <<'JSON'
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Direct answer: 42\nBecause 6 * 7 = 42.\n<<<CONTEXT\n- Hidden spec\nCONTEXT>>>"}}}
{"type":"result","subtype":"success","is_error":false}
JSON
EOF
chmod +x "$T6_CLAUDE"

(
  cd "$TMPBASE" &&
  STATE_DIR="$T6_STATE" OUT_DIR="$T6_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$T6_CLAUDE" NO_NOTIFY=1 TERM=dumb \
  exec "$TMPBASE/bin/live-review" --no-web --interval 30 >"$T6_STDOUT" 2>&1
) &
LR6_PID=$!

for _ in $(seq 1 40); do
  [ -f "$T6_OUT/latest.md" ] && grep -q "Direct answer: 42" "$T6_OUT/latest.md" 2>/dev/null && break
  sleep 0.25
done
sleep 0.2
kill -TERM "$LR6_PID" 2>/dev/null || true
wait "$LR6_PID" 2>/dev/null || true

T6_UI=$(cat "$T6_STDOUT" 2>/dev/null)
assert_eq "$(cat "$T6_STATE/web_enabled" 2>/dev/null)" "0" "live-review --no-web writes state/web_enabled=0"
assert_not_contains "$(cat "$T6_ARGS" 2>/dev/null)" "WebSearch" "live-review --no-web disables WebSearch"
assert_contains "$T6_UI" "Direct answer: 42" "live-review streams solution content directly to UI"
assert_not_contains "$T6_UI" "<<<CONTEXT" "live-review hides <<<CONTEXT marker from UI"
assert_not_contains "$T6_UI" "Hidden spec" "live-review hides saved context body from UI"
assert_not_contains "$T6_UI" "Problem context updated" "live-review hides context-updated banner from UI"
assert_not_contains "$T6_UI" "solving (" "live-review does not leak run.log debug lines into UI"
assert_not_contains "$T6_UI" "No new findings" "live-review never shows No new findings"
assert_contains "$(cat "$T6_OUT/problem_context.md" 2>/dev/null)" "Hidden spec" "live-review still persists problem_context.md silently"

# 6c. Default (web ON) writes state/web_enabled=1 and enables WebSearch
T6W_STATE="$TMPBASE/t6w_state"
T6W_OUT="$TMPBASE/t6w_out"
T6W_STDOUT="$TMPBASE/t6w_stdout.log"
T6W_ARGS="$TMPBASE/t6w_args.txt"
T6W_CLAUDE="$TMPBASE/t6w-claude"
cat > "$T6W_CLAUDE" <<EOF
#!/bin/bash
cat >/dev/null
printf '%s\n' "\$*" > "$T6W_ARGS"
echo "Answer: Paris"
EOF
chmod +x "$T6W_CLAUDE"

(
  cd "$TMPBASE" &&
  STATE_DIR="$T6W_STATE" OUT_DIR="$T6W_OUT" CAPTURE_IMAGE="$TMPBASE/page_base.png" \
  CLAUDE_BIN="$T6W_CLAUDE" NO_NOTIFY=1 TERM=dumb \
  exec "$TMPBASE/bin/live-review" --interval 30 >"$T6W_STDOUT" 2>&1
) &
LR6W_PID=$!

for _ in $(seq 1 40); do
  [ -f "$T6W_OUT/latest.md" ] && grep -q "Answer: Paris" "$T6W_OUT/latest.md" 2>/dev/null && break
  sleep 0.25
done
sleep 0.2
kill -TERM "$LR6W_PID" 2>/dev/null || true
wait "$LR6W_PID" 2>/dev/null || true

assert_eq "$(cat "$T6W_STATE/web_enabled" 2>/dev/null)" "1" "live-review enables web lookup by default (state/web_enabled=1)"
assert_contains "$(cat "$T6W_ARGS" 2>/dev/null)" "WebSearch,WebFetch" "live-review enables WebSearch,WebFetch by default"
assert_contains "$(cat "$T6W_STDOUT" 2>/dev/null)" "Answer: Paris" "live-review displays solution cleanly"

# 6d. Real PTY interactive test: live [w] toggle, [Space] instant solve, [c] clear, [q] quit
T6P_STATE="$TMPBASE/t6p_state"
T6P_OUT="$TMPBASE/t6p_out"
T6P_COUNT="$TMPBASE/t6p_count"
T6P_ARGS_LOG="$TMPBASE/t6p_args_log.txt"
echo 0 > "$T6P_COUNT"
T6P_CLAUDE="$TMPBASE/t6p-claude"
cat > "$T6P_CLAUDE" <<EOF
#!/bin/bash
cat >/dev/null
c=\$(cat "$T6P_COUNT")
c=\$((c + 1))
echo "\$c" > "$T6P_COUNT"
FLAT_ARGS=\$(printf '%s ' "\$@" | tr '\n' ' ')
printf 'CALL %s: %s\n' "\$c" "\$FLAT_ARGS" >> "$T6P_ARGS_LOG"
printf 'Solution #%s: x = 7\n<<<CONTEXT\n- PTY context\nCONTEXT>>>\n' "\$c"
EOF
chmod +x "$T6P_CLAUDE"

PTY_RES=$(python3 - "$TMPBASE/bin/live-review" "$T6P_STATE" "$T6P_OUT" "$TMPBASE/page_base.png" "$T6P_CLAUDE" "$T6P_COUNT" <<'PY'
import os, pty, select, subprocess, sys, time

cmd_bin, state_dir, out_dir, img, claude_bin, count_file = sys.argv[1:7]
master, slave = pty.openpty()
env = os.environ.copy()
env.update({
    "STATE_DIR": state_dir,
    "OUT_DIR": out_dir,
    "CAPTURE_IMAGE": img,
    "CLAUDE_BIN": claude_bin,
    "NO_NOTIFY": "1",
    "TERM": "xterm-256color",
})
proc = subprocess.Popen(
    [cmd_bin, "--interval", "20"],
    stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True
)
os.close(slave)

all_out = bytearray()

def drain(timeout=0.1):
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([master], [], [], max(0.01, end - time.time()))
        if not r:
            break
        try:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            all_out.extend(chunk)
        except OSError:
            break

def wait_for(pred, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        drain(0.05)
        if pred():
            return True
    return False

def read_file(p):
    try:
        return open(p).read().strip()
    except OSError:
        return ""

# Wait for initial solve to finish and lock to release (now calmly idle watching)
ok1 = wait_for(lambda: read_file(count_file) == "1" and read_file(os.path.join(state_dir, "status")) == "watching" and not os.path.exists(os.path.join(state_dir, "lock.d")))
# Press 'w' to toggle web OFF on the go
os.write(master, b"w")
ok_w_off = wait_for(lambda: read_file(os.path.join(state_dir, "web_enabled")) == "0", timeout=3.0)
# Press Space to force immediate re-solve with web OFF
os.write(master, b" ")
ok_force = wait_for(lambda: read_file(count_file) == "2" and read_file(os.path.join(state_dir, "status")) == "watching" and not os.path.exists(os.path.join(state_dir, "lock.d")), timeout=8.0)
drain(0.2)
# Check that the visible screen after the last clear contains ONLY Solution #2 (NOT Solution #1)
CLEAR_SEQ = b"\x1b[H\x1b[2J\x1b[3J"
parts = bytes(all_out).split(CLEAR_SEQ)
last_screen = parts[-1].decode("utf-8", errors="replace") if len(parts) > 1 else ""
only_latest = ("Solution #2" in last_screen) and ("Solution #1" not in last_screen)
# Press 'w' again to toggle web back ON
os.write(master, b"w")
ok_w_on = wait_for(lambda: read_file(os.path.join(state_dir, "web_enabled")) == "1", timeout=3.0)
# Press 'c' to clear saved context
ctx_before = os.path.exists(os.path.join(out_dir, "problem_context.md"))
os.write(master, b"c")
ok_clear = wait_for(lambda: not os.path.exists(os.path.join(out_dir, "problem_context.md")), timeout=3.0)
# Press 'q' to quit cleanly
os.write(master, b"q")
try:
    rc = proc.wait(timeout=4.0)
except subprocess.TimeoutExpired:
    proc.terminate()
    rc = proc.wait(timeout=2.0)
os.close(master)
print(f"ok1={int(ok1)} w_off={int(ok_w_off)} force={int(ok_force)} only_latest={int(only_latest)} w_on={int(ok_w_on)} ctx_before={int(ctx_before)} clear={int(ok_clear)} rc={rc}")
PY
)
assert_contains "$PTY_RES" "ok1=1" "PTY live-review completes initial solve and settles idle"
assert_contains "$PTY_RES" "w_off=1" "pressing [w] toggles web lookup OFF immediately"
assert_contains "$PTY_RES" "force=1" "pressing [Space] forces immediate solve during long interval"
assert_contains "$PTY_RES" "only_latest=1" "terminal clears prior answer so ONLY the present solution is visible"
assert_contains "$PTY_RES" "w_on=1" "pressing [w] again toggles web lookup back ON immediately"
assert_contains "$PTY_RES" "ctx_before=1 clear=1" "pressing [c] clears saved problem_context.md"
assert_contains "$PTY_RES" "rc=0" "pressing [q] exits live-review cleanly with code 0"
CALL1_LINE=$(grep '^CALL 1:' "$T6P_ARGS_LOG" 2>/dev/null || true)
CALL2_LINE=$(grep '^CALL 2:' "$T6P_ARGS_LOG" 2>/dev/null || true)
assert_contains "$CALL1_LINE" "WebSearch,WebFetch" "PTY call 1 ran with WebSearch ON"
assert_not_contains "$CALL2_LINE" "WebSearch" "PTY call 2 (after pressing [w] + [Space]) ran with WebSearch OFF"

sleep 0.2
STRAY6=$(pgrep -fl "$TMPBASE" 2>/dev/null || true)
assert_eq "$STRAY6" "" "no stray background processes left after all live-review runs"

echo
echo "=== Task 7: anti-spam guarantees on unchanged / noisy screens ==="

swift - "$TMPBASE" <<'SWIFT'
import Foundation
import AppKit

func renderPNG(path: String, lines: [String], cursor: Bool = false) {
    let w = 900, h = 900
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
        .foregroundColor: NSColor.black
    ]
    for (idx, line) in lines.enumerated() {
        let y = CGFloat(h - 40 - idx * 24)
        NSString(string: line).draw(at: NSPoint(x: 30, y: y), withAttributes: attrs)
    }
    if cursor {
        NSColor.black.setFill()
        NSRect(x: 340, y: h - 40, width: 2, height: 20).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let base = CommandLine.arguments[1]
let staticLines = (1...20).map { "Static quiz context line number \($0) on screen" }
renderPNG(path: "\(base)/t7_base.png", lines: staticLines + ["Time remaining: 14:59"])
renderPNG(path: "\(base)/t7_cursor.png", lines: staticLines + ["Time remaining: 14:59"], cursor: true)
renderPNG(path: "\(base)/t7_timer_tick.png", lines: staticLines + ["Time remaining: 14:58"])
renderPNG(path: "\(base)/t7_self_echo.png", lines: staticLines + ["Time remaining: 14:58", "Live Solver · watching screen 1", "Answer: Option C is correct"])
renderPNG(path: "\(base)/t7_real_change.png", lines: staticLines + ["Time remaining: 14:57", "Question 2: Solve 3x + 5 = 20"])
SWIFT

# 7a. helper vdiff-cells distinguishes zero/cursor noise from real changes
VC_SAME=$("$ROOT/helper" vdiff-cells "$TMPBASE/t7_base.png" "$TMPBASE/t7_base.png" 2>/dev/null)
assert_eq "$VC_SAME" "$(printf '0\t0')" "helper vdiff-cells returns 0 cells on identical image"

VC_CUR=$("$ROOT/helper" vdiff-cells "$TMPBASE/t7_base.png" "$TMPBASE/t7_cursor.png" 2>/dev/null)
assert_eq "$VC_CUR" "$(printf '0\t0')" "helper vdiff-cells returns 0 cells on blinking cursor"

VC_ADD=$("$ROOT/helper" vdiff-cells "$TMPBASE/t7_base.png" "$TMPBASE/t7_real_change.png" 2>/dev/null)
VC_ADD_CELLS="${VC_ADD%%$'\t'*}"
assert_ge "$VC_ADD_CELLS" "10" "helper vdiff-cells detects new question line (>=10 cells)"

# 7b. review.sh skips blinking cursor, ticking countdown timer, and self-output echo, but triggers on real new question
T7_STATE="$TMPBASE/t7_state"
T7_OUT="$TMPBASE/t7_out"
T7_COUNT="$TMPBASE/t7_count"
echo 0 > "$T7_COUNT"
T7_CLAUDE="$TMPBASE/t7-claude"
cat > "$T7_CLAUDE" <<EOF
#!/bin/bash
cat >/dev/null
c=\$(cat "$T7_COUNT")
echo \$((c + 1)) > "$T7_COUNT"
echo "Answer: Option C is correct"
EOF
chmod +x "$T7_CLAUDE"

STATE_DIR="$T7_STATE" OUT_DIR="$T7_OUT" CAPTURE_IMAGE="$TMPBASE/t7_base.png" \
  CLAUDE_BIN="$T7_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T7_COUNT")" "1" "initial capture solves once"

STATE_DIR="$T7_STATE" OUT_DIR="$T7_OUT" CAPTURE_IMAGE="$TMPBASE/t7_cursor.png" \
  CLAUDE_BIN="$T7_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T7_COUNT")" "1" "blinking cursor does NOT re-trigger stream"

STATE_DIR="$T7_STATE" OUT_DIR="$T7_OUT" CAPTURE_IMAGE="$TMPBASE/t7_timer_tick.png" \
  CLAUDE_BIN="$T7_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T7_COUNT")" "1" "countdown timer tick (14:59 -> 14:58) does NOT re-trigger stream"

STATE_DIR="$T7_STATE" OUT_DIR="$T7_OUT" CAPTURE_IMAGE="$TMPBASE/t7_self_echo.png" \
  CLAUDE_BIN="$T7_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T7_COUNT")" "1" "Live Solver own UI/reply lines do NOT self-trigger stream"

STATE_DIR="$T7_STATE" OUT_DIR="$T7_OUT" CAPTURE_IMAGE="$TMPBASE/t7_real_change.png" \
  CLAUDE_BIN="$T7_CLAUDE" NO_NOTIFY=1 "$ROOT/review.sh"
assert_eq "$(cat "$T7_COUNT")" "2" "real new question still triggers immediately"

# 7c. live-review running for multiple 1s poll intervals on static screen streams ONCE and stays silent
T7L_STATE="$TMPBASE/t7l_state"
T7L_OUT="$TMPBASE/t7l_out"
T7L_COUNT="$TMPBASE/t7l_count"
T7L_STDOUT="$TMPBASE/t7l_stdout.log"
echo 0 > "$T7L_COUNT"
T7L_CLAUDE="$TMPBASE/t7l-claude"
cat > "$T7L_CLAUDE" <<EOF
#!/bin/bash
cat >/dev/null
c=\$(cat "$T7L_COUNT")
echo \$((c + 1)) > "$T7L_COUNT"
echo "Single answer for static screen"
EOF
chmod +x "$T7L_CLAUDE"

(
  cd "$TMPBASE" &&
  STATE_DIR="$T7L_STATE" OUT_DIR="$T7L_OUT" CAPTURE_IMAGE="$TMPBASE/t7_base.png" \
  CLAUDE_BIN="$T7L_CLAUDE" NO_NOTIFY=1 TERM=dumb \
  exec "$TMPBASE/bin/live-review" --interval 1 >"$T7L_STDOUT" 2>&1
) &
LR7_PID=$!
sleep 3.5
kill -TERM "$LR7_PID" 2>/dev/null || true
wait "$LR7_PID" 2>/dev/null || true

assert_eq "$(cat "$T7L_COUNT")" "1" "live-review over 3+ poll ticks on static screen calls Claude only ONCE"
ANS_OCC=$(grep -c "Single answer for static screen" "$T7L_STDOUT" 2>/dev/null || echo 0)
assert_eq "$ANS_OCC" "1" "live-review streams answer only ONCE while screen is unchanged"

sleep 0.2
STRAY7=$(pgrep -fl "$TMPBASE" 2>/dev/null || true)
assert_eq "$STRAY7" "" "no stray background processes left after Task 7"

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
