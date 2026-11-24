#!/bin/bash
# Live universal on-screen problem solver for a window (default: MeowDisplay)
# or connected monitor using the local Claude Code CLI (subscription auth, no API key).
#  1. screenshot the target window or display
#  2. OCR on-device (macOS Vision) + fast visual grid diff to detect any meaningful change
#  3. stream a direct, clean solution for whatever challenge/question/task is on screen
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin:$PATH"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN  # never bill the API

resolve_dir() {
  local src="$1"
  while [ -L "$src" ]; do
    local dir
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

APP="${WINDOW_MATCH:-MeowDisplay}"
SCREEN="${SCREEN_TARGET:-}"
MODEL="${REVIEW_MODEL:-claude-sonnet-5-5}"
CLAUDE="${CLAUDE_BIN:-claude}"
DIR="${SCREENPIPE_DIR:-$(resolve_dir "$0")}"
OUT="${OUT_DIR:-$DIR/output}"
STATE="${STATE_DIR:-$DIR/state}"
LIVE_STREAM="${LIVE_STREAM:-0}"
FORCE_REVIEW="${FORCE_REVIEW:-0}"
mkdir -p "$OUT" "$STATE"
LOG="$STATE/run.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

if [ ! -x "$DIR/helper" ] || [ "$DIR/helper.swift" -nt "$DIR/helper" ]; then
  swiftc -O "$DIR/helper.swift" -o "$DIR/helper" 2>>"$LOG" || { log "failed to compile helper.swift"; exit 1; }
fi

# one run at a time (stale lock after 10 min is cleared)
LOCK="$STATE/lock.d"
find "$LOCK" -maxdepth 0 -mmin +10 -exec rm -rf {} \; 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK" "$STATE/streaming"' EXIT

status() { echo "$*" > "$STATE/status"; }
echo "0" > "$STATE/did_solve"

SHOT="$STATE/screen.png"
if [ -n "${CAPTURE_IMAGE:-}" ]; then
  if [ ! -s "$CAPTURE_IMAGE" ]; then
    log "capture override missing: $CAPTURE_IMAGE"
    status "screenshot failed"
    exit 0
  fi
  cp "$CAPTURE_IMAGE" "$SHOT"
  CAPTURE_DESC="${CAPTURE_DESC_OVERRIDE:-image $(basename "$CAPTURE_IMAGE")}"
elif [ -n "$SCREEN" ]; then
  SCREEN_INFO=$("$DIR/helper" screen "$SCREEN") || { status "screen '$SCREEN' not found - connect it"; exit 0; }
  DIDX="${SCREEN_INFO%%$'\t'*}"
  DNAME="${SCREEN_INFO#*$'\t'}"
  CAPTURE_DESC="screen $DIDX ($DNAME)"
  screencapture -x -D "$DIDX" "$SHOT" 2>>"$LOG" || { log "screenshot failed ($CAPTURE_DESC)"; status "screenshot failed"; exit 0; }
else
  WID=$("$DIR/helper" winid "$APP") || { status "$APP window not found - open it"; exit 0; }
  CAPTURE_DESC="window $APP"
  screencapture -x -o -l "$WID" "$SHOT" 2>>"$LOG" || { log "screenshot failed ($CAPTURE_DESC)"; status "screenshot failed"; exit 0; }
fi

if [ ! -s "$SHOT" ]; then
  log "empty screenshot ($CAPTURE_DESC)"
  status "screenshot failed"
  exit 0
fi

# If our own Live Solver terminal is visible on the watched monitor, mask it out
# so streaming our own answer can never trigger a self-capture feedback loop.
if [ -n "$SCREEN" ] && [ -z "${CAPTURE_IMAGE:-}" ]; then
  if "$DIR/helper" mask "$SHOT" "$STATE/screen_masked.png" "$SCREEN" "Live Solver" 2>/dev/null; then
    mv "$STATE/screen_masked.png" "$SHOT"
  fi
fi

# Fast Pixel-First + Jitter-Resistant Dual Change Detection
CHANGE_REASON=""
TEXT=""
if [ "$FORCE_REVIEW" = "1" ]; then
  CHANGE_REASON="manual trigger"
elif [ ! -f "$STATE/last_reviewed.png" ] || [ ! -f "$STATE/last_reviewed.txt" ]; then
  CHANGE_REASON="initial capture"
else
  VINFO=$("$DIR/helper" vdiff-cells "$STATE/last_reviewed.png" "$SHOT" 2>/dev/null || echo "99999	100")
  VCELLS="${VINFO%%$'\t'*}"
  VPCT="${VINFO#*$'\t'}"
  if [ "${VCELLS:-0}" -eq 0 ] 2>/dev/null; then
    # Zero visual pixels changed below menu bar -> skip Vision OCR & Claude completely
    status "watching"
    exit 0
  elif [ "${VPCT:-0}" -ge 2 ] 2>/dev/null; then
    CHANGE_REASON="visual changed (${VPCT}%)"
  else
    # Small localized visual change (e.g. new line, small edit, or countdown timer):
    # verify via OCR whether meaningful non-volatile text actually changed.
    TEXT=$("$DIR/helper" ocr "$SHOT" 2>/dev/null || true)
    printf '%s' "$TEXT" > "$STATE/current.txt"
    TEXT_CHANGE=$(python3 -I -c '
from collections import Counter
import re, sys

CLOCK_RE = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APMapm]{2})?\b")
WEEKDAY_RE = re.compile(r"\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\b.*", re.I)
REL_AGE_RE = re.compile(r"\b\d+\s*(?:s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\s+ago\b", re.I)
UI_NOISE_RE = re.compile(r"(Live Solver|───\s*\d{2}:\d{2}:\d{2}|●\s*watching|◌\s*(?:solving|searching web)|⏸\s*paused|\[w\]\s*web)", re.I)
TOKEN_RE = re.compile(r"[A-Za-z0-9_+#=^]+")

def load_clean_lines(path):
    lines = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for l in f:
                s = l.strip()
                if not s or UI_NOISE_RE.search(s):
                    continue
                s = WEEKDAY_RE.sub(" ", s)
                s = CLOCK_RE.sub(" ", s)
                s = REL_AGE_RE.sub(" ", s)
                s = re.sub(r"\s+", " ", s).strip()
                if s:
                    lines.append(s)
    except OSError:
        pass
    return lines

def to_tokens(lines):
    c = Counter()
    for s in lines:
        for tok in TOKEN_RE.findall(s.lower()):
            if len(tok) >= 2 or tok.isdigit():
                c[tok] += 1
    return c

lines_a = load_clean_lines(sys.argv[1])
lines_b = load_clean_lines(sys.argv[2])
own_lines = set(load_clean_lines(sys.argv[3])) if len(sys.argv) > 3 else set()

# Remove lines belonging to our own last rendered solution (self-capture fallback guard)
lines_a = [l for l in lines_a if l not in own_lines]
lines_b = [l for l in lines_b if l not in own_lines]

wa = to_tokens(lines_a)
wb = to_tokens(lines_b)

added = wb - wa
removed = wa - wb
add_cnt = sum(added.values())
rem_cnt = sum(removed.values())
delta_words = add_cnt + rem_cnt
add_chars = sum(len(w) * n for w, n in added.items())
rem_chars = sum(len(w) * n for w, n in removed.items())
digit_changed = any(any(ch.isdigit() for ch in w) for w in (set(added) | set(removed)))

union_cnt = sum((wa | wb).values())
inter_cnt = sum((wa & wb).values())
sim = int(100 * inter_cnt / max(1, union_cnt)) if union_cnt else 100

changed = (
    (delta_words >= 3)
    or (add_chars >= 10)
    or (rem_chars >= 10)
    or (digit_changed and delta_words >= 2)
    or (sim < 95 and delta_words >= 2)
)
print(f"{1 if changed else 0} {sim} {add_cnt} {rem_cnt}")
' "$STATE/last_reviewed.txt" "$STATE/current.txt" "$OUT/latest.md")
    read -r TXT_CHANGED SIM ADDED_CNT REMOVED_CNT <<< "$TEXT_CHANGE"
    if [ "$TXT_CHANGED" = "1" ]; then
      CHANGE_REASON="text changed (sim ${SIM}%, +${ADDED_CNT}/-${REMOVED_CNT} words)"
    fi
  fi
fi

if [ -z "$CHANGE_REASON" ]; then
  status "watching"
  exit 0
fi

# Run OCR now if we skipped it on the fast path (initial / manual / visual-change trigger)
if [ -z "$TEXT" ]; then
  TEXT=$("$DIR/helper" ocr "$SHOT" 2>/dev/null || true)
  printf '%s' "$TEXT" > "$STATE/current.txt"
fi

# Live web-search toggle: state/web_enabled wins when managed by live-review; default ON (1)
if [ -f "$STATE/web_enabled" ]; then
  WEB_ENABLED=$(tr -d '[:space:]' < "$STATE/web_enabled")
else
  WEB_ENABLED="${WEB_SEARCH:-1}"
fi
[ "$WEB_ENABLED" = "0" ] || WEB_ENABLED="1"

status "solving..."

# Snapshot what we are actually sending to Claude so mid-run screen changes are not lost
cp "$SHOT" "$STATE/reviewing_src.png"
cp "$STATE/current.txt" "$STATE/reviewing.txt"
REVIEW_IMG="$STATE/reviewing.jpg"
if ! "$DIR/helper" prep "$STATE/reviewing_src.png" "$REVIEW_IMG" 1920 2>>"$LOG"; then
  REVIEW_IMG="$STATE/reviewing_src.png"
fi

PREV=$(tail -c 4000 "$OUT/history.md" 2>/dev/null || true)
[ -z "$PREV" ] && PREV="(none yet)"

CTX_FILE="$OUT/problem_context.md"
CTX=$(cat "$CTX_FILE" 2>/dev/null || true)
[ -z "$CTX" ] && CTX="(none captured yet)"

OCR_HINT="$TEXT"
[ -z "$OCR_HINT" ] && OCR_HINT="(no OCR text detected - rely directly on the attached screenshot)"

if [ "$WEB_ENABLED" = "1" ]; then
  WEB_RULE="Web lookup is ON: solve directly when confident. If the challenge depends on external facts, documentation, library/API details, obscure errors, or information worth verifying, call WebSearch/WebFetch silently first (without writing filler like 'Let me search...') and then output only the clean solution."
else
  WEB_RULE="Web lookup is OFF: solve directly using the attached screenshot, saved context, and your own knowledge."
fi

cat > "$STATE/sys_prompt.txt" <<EOF
You are a live on-screen problem solver watching a user's screen.
For EVERY screenshot you receive, actively identify what needs to be solved, answered, fixed, completed, or decided on screen and immediately provide the concrete solution.

Never reply with "No new findings", "Nothing to solve", or "There is no challenge on screen". Always look closely at the screenshot — whether it is a quiz, multiple-choice question, math/logic/aptitude puzzle, blank or partial coding challenge, buggy code, stack trace/CLI error, SQL/regex/spreadsheet formula, chart/diagram/visual puzzle, form, interview/open-ended question, reading prompt, message/email needing a reply, or an active workspace — and give the direct, actionable solution or best concrete next action for what is shown.

Ignore OS chrome (menu bar, dock, window frames, file trees) and ignore any "Live Solver" or "Live code review" terminal window itself.

Output ONLY the information relevant to solving the problem on screen:
- Lead immediately with the direct answer or solution.
- NO greetings, NO "Looking at: ...", NO "Here is the solution:", NO "Let me search...", NO filler or meta-commentary.
- Adapt format to the challenge:
  * Multiple choice / quiz / form: exact answer option(s) first, then 1 brief line explaining why.
  * Math / logic / puzzle / diagram / chart: final answer first, then the shortest clear derivation.
  * Coding problem (empty or incomplete editor): concise working solution.
  * Existing code with bugs or unmet requirements: minimal targeted fix (file/line if visible, 1-line cause, before -> after) — no unnecessary rewrites or style nits.
  * Error / stack trace / CLI / config: root cause in 1 line + exact fix or command.
  * Open-ended / interview / writing / general task: direct concise answer, suggested reply, or concrete step-by-step action.

If the screen displays multi-part problem instructions, constraints, or background specifications that may scroll away later, silently append an updated concise bullet summary (merging with earlier context, max ~60 lines, newest wins) at the very end wrapped between a line containing only <<<CONTEXT and a line containing only CONTEXT>>>. Even when capturing context, ALWAYS still provide the concrete solution for what is currently on screen above the context block.

$WEB_RULE
EOF

cat > "$STATE/user_prompt.txt" <<EOF
Watching: $CAPTURE_DESC
The attached screenshot is the source of truth; on-device OCR below is a supplementary hint.

=== SAVED CONTEXT (from earlier screens) ===
$CTX

=== RECENT SOLUTIONS (for continuity; always still give the complete solution for what is currently on screen) ===
$PREV

=== OCR HINT ===
$OCR_HINT
EOF

DIVIDER_TIME=$(date '+%H:%M:%S')
log "solving ($CHANGE_REASON) on $CAPTURE_DESC with $MODEL (web=$WEB_ENABLED)..."

python3 -I "$DIR/solver_stream.py" \
  --claude "$CLAUDE" \
  --model "$MODEL" \
  --image "$REVIEW_IMG" \
  --system-prompt-file "$STATE/sys_prompt.txt" \
  --prompt-file "$STATE/user_prompt.txt" \
  --web "$WEB_ENABLED" \
  --status-file "$STATE/status" \
  --streaming-flag "$STATE/streaming" \
  --reply-out "$STATE/reply.out" \
  --context-out "$STATE/context.out" \
  --err-out "$STATE/err.out" \
  --live-stream "$LIVE_STREAM" \
  --divider-time "$DIVIDER_TIME" \
  --add-dir "$STATE" \
  --cwd "$DIR"
STATUS=$?

RESULT=$(cat "$STATE/reply.out" 2>/dev/null || true)
if [ $STATUS -ne 0 ] || [ -z "$RESULT" ]; then
  ERR_DETAIL=$(tr '\n' ' ' < "$STATE/err.out" 2>/dev/null | cut -c1-160)
  log "claude failed (exit $STATUS)${ERR_DETAIL:+: $ERR_DETAIL} - will retry"
  status "retrying..."
  exit 0
fi

cp "$STATE/reviewing.txt" "$STATE/last_reviewed.txt"
cp "$STATE/reviewing_src.png" "$STATE/last_reviewed.png"
echo "1" > "$STATE/did_solve"
status "watching"

# Silently persist updated problem context without cluttering the user view
NEWCTX=$(cat "$STATE/context.out" 2>/dev/null || true)
if [ -n "$NEWCTX" ]; then
  printf '%s\n' "$NEWCTX" > "$CTX_FILE"
  log "problem context updated -> output/problem_context.md"
fi

{ printf '\n\033[2m─── %s ───\033[0m\n' "$DIVIDER_TIME"; printf '%s\n' "$RESULT"; } >> "$OUT/feed.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')
{ echo "## $TS"; echo; printf '%s\n' "$RESULT"; echo; } > "$OUT/latest.md"
{ echo "## $TS"; echo; printf '%s\n' "$RESULT"; echo; } >> "$OUT/history.md"
log "solved -> output/latest.md"

if [ "${NO_NOTIFY:-0}" != "1" ]; then
  FIRST_LINE=$(printf '%s' "$RESULT" | grep -m1 -v '^\s*$' | tr -d '"#' | cut -c1-120)
  osascript -e "display notification \"$FIRST_LINE\" with title \"Live Solver\"" 2>/dev/null || true
fi
