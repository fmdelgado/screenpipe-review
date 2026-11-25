#!/bin/bash
# Live universal on-screen problem solver for a window (default: MeowDisplay)
# or connected monitor using the local Claude Code CLI (subscription auth, no API key).
#  1. screenshot the target window or display
#  2. fast visual grid diff + word-multiset OCR diff to skip unchanged/jittery screens
#  3. hands-free scroll-settle capture accumulates multi-screen problems into one multi-image call
#  4. verifies complete problem definition before answering, streaming clean output directly
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
CLEAR_ON_START="${CLEAR_ON_START:-0}"
LIVE_HEADER="${LIVE_HEADER:-}"
FORCE_REVIEW="${FORCE_REVIEW:-0}"
SCROLL_SETTLE="${SCROLL_SETTLE:-1.2}"
MAX_PAGES="${MAX_PAGES:-5}"
PAGE_IDLE_RESET_SECS="${PAGE_IDLE_RESET_SECS:-90}"

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

# Resolve capture target once up front so settle probes reuse the exact same display/window
DIDX=""
WID=""
if [ -n "${CAPTURE_CMD:-}" ]; then
  CAPTURE_DESC="${CAPTURE_DESC_OVERRIDE:-capture script}"
elif [ -n "${CAPTURE_IMAGE:-}" ]; then
  CAPTURE_DESC="${CAPTURE_DESC_OVERRIDE:-image $(basename "$CAPTURE_IMAGE")}"
elif [ -n "$SCREEN" ]; then
  SCREEN_INFO=$("$DIR/helper" screen "$SCREEN") || { status "screen '$SCREEN' not found - connect it"; exit 0; }
  DIDX="${SCREEN_INFO%%$'\t'*}"
  DNAME="${SCREEN_INFO#*$'\t'}"
  CAPTURE_DESC="screen $DIDX ($DNAME)"
else
  WID=$("$DIR/helper" winid "$APP") || { status "$APP window not found - open it"; exit 0; }
  CAPTURE_DESC="window $APP"
fi

capture_once() {
  local dst="$1"
  rm -f "$dst"
  if [ -n "${CAPTURE_CMD:-}" ]; then
    "$CAPTURE_CMD" "$dst" 2>>"$LOG" || return 1
  elif [ -n "${CAPTURE_IMAGE:-}" ]; then
    [ -s "$CAPTURE_IMAGE" ] || return 1
    cp "$CAPTURE_IMAGE" "$dst"
  elif [ -n "$SCREEN" ]; then
    screencapture -x -D "$DIDX" "$dst" 2>>"$LOG" || return 1
    # Mask our own Live Solver terminal if visible on the watched monitor
    if "$DIR/helper" mask "$dst" "${dst}.masked.png" "$SCREEN" "Live Solver" 2>/dev/null; then
      mv "${dst}.masked.png" "$dst"
    fi
  else
    screencapture -x -o -l "$WID" "$dst" 2>>"$LOG" || return 1
  fi
  [ -s "$dst" ]
}

SHOT="$STATE/screen.png"
if ! capture_once "$SHOT"; then
  log "screenshot failed ($CAPTURE_DESC)"
  status "screenshot failed"
  exit 0
fi

AWAITING_MORE="0"
[ -f "$STATE/awaiting_more" ] && AWAITING_MORE=$(tr -d '[:space:]' < "$STATE/awaiting_more")

# Fast Pixel-First + Jitter-Resistant Dual Change Detection (with Smart Typing Shield)
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
  # Sensitive threshold while waiting for scroll (awaiting_more=1);
  # Smart Typing Shield once a complete solution is already on screen (awaiting_more=0).
  VDIFF_THRESH=12
  [ "$AWAITING_MORE" = "1" ] && VDIFF_THRESH=2

  if [ "${VCELLS:-0}" -eq 0 ] 2>/dev/null; then
    # Zero visual pixels changed below menu bar -> skip Vision OCR & Claude completely
    status "watching"
    exit 0
  elif [ "${VPCT:-0}" -ge "$VDIFF_THRESH" ] 2>/dev/null; then
    CHANGE_REASON="visual changed (${VPCT}%)"
  else
    # Localized visual change: verify via OCR whether the problem itself changed
    # (vs typing an answer into the current question, timer ticks, or OCR jitter).
    TEXT=$("$DIR/helper" ocr "$SHOT" 2>/dev/null || true)
    printf '%s' "$TEXT" > "$STATE/current.txt"
    TEXT_CHANGE=$(python3 -I -c '
from collections import Counter
import re, sys

CLOCK_RE = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APMapm]{2})?\b")
WEEKDAY_RE = re.compile(r"\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\b.*", re.I)
REL_AGE_RE = re.compile(r"\b\d+\s*(?:s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\s+ago\b", re.I)
UI_NOISE_RE = re.compile(r"(Live Solver|───\s*\d{2}:\d{2}:\d{2}|●\s*watching|◌\s*(?:solving|searching web|capturing)|⏸\s*paused|\[w\]\s*web)", re.I)
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
awaiting_more = (sys.argv[4] == "1") if len(sys.argv) > 4 else False
vpct = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5].isdigit() else 0

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

total_a = sum(wa.values())
union_cnt = sum((wa | wb).values())
inter_cnt = sum((wa & wb).values())
sim = int(100 * inter_cnt / max(1, union_cnt)) if union_cnt else 100
retained = int(100 * inter_cnt / max(1, total_a)) if total_a else 100

if awaiting_more:
    # Sensitive mode while collecting remaining scrolls of an incomplete problem
    changed = (
        (delta_words >= 3)
        or (add_chars >= 10)
        or (rem_chars >= 10)
        or (digit_changed and delta_words >= 2)
        or (sim < 95 and delta_words >= 2)
    )
else:
    # Smart Typing Shield: once a complete solution is shown, typing into the current
    # question retains almost all existing words (retained >= 80%, rem_cnt < 8).
    # Auto-trigger only when the question/screen actually shifts or gets replaced.
    changed = (
        (total_a >= 6 and retained < 80)
        or (rem_cnt >= 8 and add_cnt >= 8)
        or (total_a < 6 and add_cnt >= 6)
        or (total_a < 10 and vpct >= 4)
    )
print(f"{1 if changed else 0} {sim} {retained} {add_cnt} {rem_cnt}")
' "$STATE/last_reviewed.txt" "$STATE/current.txt" "$OUT/latest.md" "$AWAITING_MORE" "$VPCT")
    read -r TXT_CHANGED SIM RETAINED ADDED_CNT REMOVED_CNT <<< "$TEXT_CHANGE"
    if [ "$TXT_CHANGED" = "1" ]; then
      CHANGE_REASON="text changed (sim ${SIM}%, retained ${RETAINED}%, +${ADDED_CNT}/-${REMOVED_CNT} words)"
    fi
  fi
fi

if [ -z "$CHANGE_REASON" ]; then
  status "watching"
  exit 0
fi

# Run OCR now if skipped on the fast path (initial / manual / visual-change trigger)
if [ -z "$TEXT" ]; then
  TEXT=$("$DIR/helper" ocr "$SHOT" 2>/dev/null || true)
  printf '%s' "$TEXT" > "$STATE/current.txt"
fi

# === Rolling Multi-Scroll Page Buffer ($STATE/pages/) ===
PAGES_DIR="$STATE/pages"
mkdir -p "$PAGES_DIR"

# Auto-reset rolling page buffer when switching to an unrelated problem (unless awaiting_more=1)
if [ "$AWAITING_MORE" != "1" ] && [ "$FORCE_REVIEW" != "1" ] && [ -f "$PAGES_DIR/last_page.txt" ]; then
  SHOULD_RESET=$(python3 -I -c '
from collections import Counter
import os, re, sys, time

prev_txt, curr_txt, idle_limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    age = time.time() - os.path.getmtime(prev_txt)
except OSError:
    age = 0
if age > idle_limit:
    print("1")
    sys.exit(0)

STOP = {"the","and","for","are","with","that","this","from","you","not","have","your","can","will","all","one","two","what","how","which","into","more","when","then","only"}
TOK = re.compile(r"[a-zA-Z0-9_]{3,}")
def toks(p):
    c = Counter()
    try:
        for t in TOK.findall(open(p, encoding="utf-8", errors="replace").read().lower()):
            if t not in STOP:
                c[t] += 1
    except OSError:
        pass
    return c

a, b = toks(prev_txt), toks(curr_txt)
na, nb = sum(a.values()), sum(b.values())
if na == 0 or nb == 0:
    print("0")
    sys.exit(0)
overlap = int(100 * sum((a & b).values()) / max(1, min(na, nb)))
print("1" if overlap < 15 else "0")
' "$PAGES_DIR/last_page.txt" "$STATE/current.txt" "$PAGE_IDLE_RESET_SECS")
  if [ "$SHOULD_RESET" = "1" ]; then
    rm -rf "$PAGES_DIR"
    mkdir -p "$PAGES_DIR"
    log "switched to new problem -> reset rolling page buffer"
  fi
fi

page_count() {
  local cnt=0 f
  for f in "$PAGES_DIR"/page_*.jpg; do
    [ -f "$f" ] && cnt=$((cnt + 1))
  done
  echo "$cnt"
}

append_page() {
  local src_png="$1"
  local ocr_file="$2"
  # Skip if visually identical to the last buffered page
  if [ -f "$PAGES_DIR/last_raw.png" ]; then
    local vinfo vcells
    vinfo=$("$DIR/helper" vdiff-cells "$PAGES_DIR/last_raw.png" "$src_png" 2>/dev/null || echo "999	100")
    vcells="${vinfo%%$'\t'*}"
    if [ "${vcells:-0}" -eq 0 ] 2>/dev/null; then
      return 0
    fi
  fi
  local seq
  seq=$(cat "$PAGES_DIR/seq" 2>/dev/null || echo "0")
  seq=$((seq + 1))
  echo "$seq" > "$PAGES_DIR/seq"
  local dst
  dst=$(printf '%s/page_%04d.jpg' "$PAGES_DIR" "$seq")
  if ! "$DIR/helper" prep "$src_png" "$dst" 1600 2>>"$LOG"; then
    cp "$src_png" "$dst"
  fi
  cp "$src_png" "$PAGES_DIR/last_raw.png"
  [ -f "$ocr_file" ] && cp "$ocr_file" "$PAGES_DIR/last_page.txt"

  # Trim oldest pages if exceeding MAX_PAGES
  local cur_cnt
  cur_cnt=$(page_count)
  while [ "$cur_cnt" -gt "$MAX_PAGES" ]; do
    local oldest
    oldest=$(ls -1 "$PAGES_DIR"/page_*.jpg 2>/dev/null | head -n 1)
    [ -n "$oldest" ] && rm -f "$oldest" || break
    cur_cnt=$((cur_cnt - 1))
  done
}

append_page "$SHOT" "$STATE/current.txt"

# Hands-free scroll-settle debounce: if user keeps scrolling, accumulate pages before calling Claude
if [ "$FORCE_REVIEW" != "1" ] && [ -n "$SCROLL_SETTLE" ] && [ "$SCROLL_SETTLE" != "0" ] && [ "$SCROLL_SETTLE" != "0.0" ]; then
  SETTLE_STEPS=0
  while [ "$SETTLE_STEPS" -lt "$MAX_PAGES" ]; do
    CUR_PAGES=$(page_count)
    if [ "$CUR_PAGES" -eq 1 ]; then
      status "capturing (1 page)..."
    else
      status "capturing (${CUR_PAGES} pages)..."
    fi
    sleep "$SCROLL_SETTLE"
    PROBE="$STATE/settle_probe.png"
    if ! capture_once "$PROBE"; then
      break
    fi
    PINFO=$("$DIR/helper" vdiff-cells "$SHOT" "$PROBE" 2>/dev/null || echo "0	0")
    PCELLS="${PINFO%%$'\t'*}"
    if [ "${PCELLS:-0}" -ge 15 ] 2>/dev/null; then
      mv "$PROBE" "$SHOT"
      TEXT=$("$DIR/helper" ocr "$SHOT" 2>/dev/null || true)
      printf '%s' "$TEXT" > "$STATE/current.txt"
      append_page "$SHOT" "$STATE/current.txt"
      SETTLE_STEPS=$((SETTLE_STEPS + 1))
      CHANGE_REASON="scrolled (${SETTLE_STEPS} extra capture(s))"
    else
      rm -f "$PROBE"
      break
    fi
  done
fi

# Collect all accumulated pages chronologically
IMAGE_ARGS=()
PAGE_CNT=0
for pf in "$PAGES_DIR"/page_*.jpg; do
  if [ -f "$pf" ]; then
    IMAGE_ARGS+=(--image "$pf")
    PAGE_CNT=$((PAGE_CNT + 1))
  fi
done
if [ "$PAGE_CNT" -eq 0 ]; then
  REVIEW_IMG="$STATE/reviewing.jpg"
  if ! "$DIR/helper" prep "$SHOT" "$REVIEW_IMG" 1600 2>>"$LOG"; then
    REVIEW_IMG="$SHOT"
  fi
  IMAGE_ARGS=(--image "$REVIEW_IMG")
  PAGE_CNT=1
fi

# Re-read live web-search toggle right after settle so a keypress mid-scroll takes effect immediately
if [ -f "$STATE/web_enabled" ]; then
  WEB_ENABLED=$(tr -d '[:space:]' < "$STATE/web_enabled")
else
  WEB_ENABLED="${WEB_SEARCH:-1}"
fi
[ "$WEB_ENABLED" = "0" ] || WEB_ENABLED="1"

status "solving..."

# Snapshot final view sent to Claude so mid-run screen changes are not lost
cp "$SHOT" "$STATE/reviewing_src.png"
cp "$STATE/current.txt" "$STATE/reviewing.txt"

CTX_FILE="$OUT/problem_context.md"
CTX=$(cat "$CTX_FILE" 2>/dev/null || true)
[ -z "$CTX" ] && CTX="(none captured yet)"

OCR_HINT="$TEXT"
[ -z "$OCR_HINT" ] && OCR_HINT="(no OCR text detected - rely directly on the attached screenshot(s))"

if [ "$WEB_ENABLED" = "1" ]; then
  WEB_RULE="Web lookup is ON: solve directly when confident. If the challenge depends on external facts, documentation, library/API details, obscure errors, or information worth verifying, call WebSearch/WebFetch silently first (without writing filler like 'Let me search...') and then output only the clean solution."
else
  WEB_RULE="Web lookup is OFF: solve directly using the attached screenshot(s), saved context, and your own knowledge."
fi

if [ "$FORCE_REVIEW" = "1" ]; then
  COMPLETENESS_RULE="The user manually pressed Solve Now. Do NOT ask to scroll down — immediately provide the best complete, actionable solution using all attached screenshot(s) and saved context."
else
  COMPLETENESS_RULE="COMPLETENESS CHECK (multi-scroll problems):
Inspect ALL attached screenshot(s) in chronological order together with SAVED CONTEXT.
- If a critical part of the problem definition is clearly cut off at the bottom/top edge or explicitly referenced as below/above and NOT YET visible in any attached screenshot (for example: a data table row is cut off mid-text, a referenced denominator/lookup table or code snippet is not shown yet, or the actual task questions/options/deliverables have not appeared yet):
  Do NOT guess an incomplete solution. Output ONLY these 3 short lines:
  ⬇ Scroll down to capture the rest
  Missing: <concise list of the exact missing parts>
  (Press Space to solve now with what's captured)
  Then silently append all exact facts/rows captured so far inside <<<CONTEXT ... CONTEXT>>>.
- Otherwise — if the attached screenshot(s) contain the full problem definition needed to solve accurately (including single-screen quizzes, coding prompts, errors, messages, diagrams, or scrolled docs where the complete problem is now visible) — immediately output ONLY the direct, complete solution."
fi

cat > "$STATE/sys_prompt.txt" <<EOF
You are a live on-screen problem solver watching a user's screen.
For EVERY screenshot set you receive, actively identify the single present challenge, question, error, or task visible on screen and provide its concrete solution (or, if critical parts of a long problem definition are visibly cut off, ask the user to scroll down so you can solve with the complete definition).

Never reply with "No new findings", "Nothing to solve", or "There is no challenge on screen". Always inspect all attached screenshots closely — whether it is a quiz, multiple-choice question, math/logic/aptitude puzzle, blank or partial coding challenge, buggy code, stack trace/CLI error, SQL/regex/spreadsheet formula, chart/diagram/visual puzzle, data-quality/case work sample, form, interview/open-ended question, reading prompt, message/email needing a reply, or an active workspace.

Ignore OS chrome (menu bar, dock, window frames, file trees) and ignore any "Live Solver" or "Live code review" terminal window itself.

$COMPLETENESS_RULE

Output ONLY the information relevant to solving the PRESENT problem on screen:
- Lead immediately with the direct answer or solution.
- NEVER recap, list, or repeat previous unrelated questions or earlier solutions — answer ONLY the present problem across the attached screenshot(s).
- NO greetings, NO "Looking at: ...", NO "Here is the solution:", NO "Let me search...", NO filler or meta-commentary.
- Adapt format to the challenge:
  * Multiple choice / quiz / form: exact answer option(s) first, then 1 brief line explaining why.
  * Math / logic / puzzle / diagram / chart: final answer first, then the shortest clear derivation.
  * Coding problem (empty or incomplete editor): concise working solution.
  * Existing code with bugs or unmet requirements: minimal targeted fix (file/line if visible, 1-line cause, before -> after) — no unnecessary rewrites or style nits.
  * Error / stack trace / CLI / config: root cause in 1 line + exact fix or command.
  * Open-ended / work sample / interview / writing / general task: direct concise answer, structured deliverable, suggested reply, or concrete step-by-step action.

If the screen displays multi-part problem instructions, constraints, or background specifications that may scroll away later, silently append an updated concise bullet summary (merging with earlier context, max ~60 lines, newest wins) at the very end wrapped between a line containing only <<<CONTEXT and a line containing only CONTEXT>>>.

$WEB_RULE
EOF

cat > "$STATE/user_prompt.txt" <<EOF
Watching: $CAPTURE_DESC ($PAGE_CNT screenshot(s) attached in scroll order)
The attached screenshot(s) are the source of truth; on-device OCR of the current view is below as a supplementary hint.

=== SAVED CONTEXT (background requirements from earlier screens, if relevant to the current problem) ===
$CTX

=== OCR HINT (current view) ===
$OCR_HINT
EOF

DIVIDER_TIME=$(date '+%H:%M:%S')
log "solving ($CHANGE_REASON, ${PAGE_CNT} page(s)) on $CAPTURE_DESC with $MODEL (web=$WEB_ENABLED)..."

python3 -I "$DIR/solver_stream.py" \
  --claude "$CLAUDE" \
  --model "$MODEL" \
  "${IMAGE_ARGS[@]}" \
  --system-prompt-file "$STATE/sys_prompt.txt" \
  --prompt-file "$STATE/user_prompt.txt" \
  --web "$WEB_ENABLED" \
  --status-file "$STATE/status" \
  --streaming-flag "$STATE/streaming" \
  --reply-out "$STATE/reply.out" \
  --context-out "$STATE/context.out" \
  --err-out "$STATE/err.out" \
  --live-stream "$LIVE_STREAM" \
  --clear-on-start "$CLEAR_ON_START" \
  --header-text "$LIVE_HEADER" \
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

# Track whether Claude asked the user to scroll down for the rest of the problem definition
FIRST_NONEMPTY=$(printf '%s\n' "$RESULT" | grep -m1 -v '^[[:space:]]*$' || true)
case "$FIRST_NONEMPTY" in
  ⬇*)
    echo "1" > "$STATE/awaiting_more"
    log "incomplete problem definition (${PAGE_CNT} page(s) buffered) -> awaiting scroll"
    ;;
  *)
    echo "0" > "$STATE/awaiting_more"
    log "solved (${PAGE_CNT} page(s)) -> output/latest.md"
    ;;
esac

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

if [ "${NO_NOTIFY:-0}" != "1" ] && [ "$(cat "$STATE/awaiting_more" 2>/dev/null)" != "1" ]; then
  FIRST_LINE=$(printf '%s' "$RESULT" | grep -m1 -v '^\s*$' | tr -d '"#' | cut -c1-120)
  osascript -e "display notification \"$FIRST_LINE\" with title \"Live Solver\"" 2>/dev/null || true
fi
