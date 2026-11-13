#!/bin/bash
# Live code review of the MeowDisplay window using the local Claude Code CLI
# (subscription auth, no API key). Runs every 10s via launchd.
#  1. screenshot the MeowDisplay window (works even if it's behind other windows)
#  2. OCR it on-device (macOS Vision) - free, used to detect changes
#  3. only if the screen meaningfully changed: ask Claude to review image + text
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin:$PATH"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN  # never bill the API

APP="${WINDOW_MATCH:-MeowDisplay}"
MODEL="${REVIEW_MODEL:-claude-sonnet-5-5}"
DIR="$HOME/screenpipe-review"
OUT="$DIR/output"
STATE="$DIR/state"
mkdir -p "$OUT" "$STATE"
LOG="$STATE/run.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# one run at a time (stale lock after 10 min is cleared)
LOCK="$STATE/lock.d"
find "$LOCK" -maxdepth 0 -mmin +10 -exec rm -rf {} \; 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK"' EXIT

status() { echo "$*" > "$STATE/status"; }
WID=$("$DIR/helper" winid "$APP") || { status "$APP window not found - open it"; exit 0; }
SHOT="$STATE/screen.png"
screencapture -x -o -l "$WID" "$SHOT" 2>>"$LOG" || { log "screenshot failed"; exit 0; }
TEXT=$("$DIR/helper" ocr "$SHOT")
[ -z "$TEXT" ] && { log "no text on screen (or no Screen Recording permission)"; exit 0; }

# skip if the text is ~the same as the last reviewed screen (ignores OCR jitter)
printf '%s' "$TEXT" > "$STATE/current.txt"
SIM=$(python3 -I -c '
import sys
def lines(path):
    try: return {l.strip() for l in open(path) if len(l.strip()) > 2}
    except OSError: return set()
a, b = lines(sys.argv[1]), lines(sys.argv[2])
print(int(100 * len(a & b) / max(1, len(a | b))))
' "$STATE/last_reviewed.txt" "$STATE/current.txt")
[ "$SIM" -ge 90 ] && { status "screen unchanged (${SIM}% same) - waiting for changes"; exit 0; }
status "reviewing..."

cp "$SHOT" "$STATE/reviewing.png"
PREV=$(tail -c 6000 "$OUT/history.md" 2>/dev/null)
[ -z "$PREV" ] && PREV="(none yet)"

CTX_FILE="$OUT/problem_context.md"
CTX=$(cat "$CTX_FILE" 2>/dev/null)
[ -z "$CTX" ] && CTX="(none captured yet)"

PROMPT="You are a continuous code-review assistant watching a mirrored screen.
Screenshot of the current screen: $STATE/reviewing.png  (Read it - it is the source of truth)
On-device OCR of that screenshot is below as a hint; OCR may garble characters and interleave columns.

1. CODE: review code visible in the editor area (ignore file trees, tabs, menus).
   Judge it primarily against the PROBLEM CONTEXT below: what must be fixed so the code does what
   the problem definition requires (plus real bugs that would break it: syntax/runtime/logic errors).
   Do NOT suggest refactors, style changes, renames, extra features, or nice-to-haves.
   For each finding, suggest the SMALLEST possible fix: change only the lines needed, show just
   those lines (before -> after), no rewritten functions or files.
   Format per finding: file + line if visible, one sentence on what is wrong (cite the requirement
   it violates when relevant), then the minimal fix. Be terse.
   Report only NEW findings not already covered in the previous findings.
2. PROBLEM DEFINITIONS: if the screen shows a written problem definition, task, spec, requirements,
   issue, acceptance criteria or design doc, read it carefully. Then, at the very end of your reply,
   output the UPDATED problem context: the existing context merged with what you just read
   (keep it a concise bullet summary, max ~60 lines, newest info wins on conflicts), wrapped
   between a line containing only <<<CONTEXT and a line containing only CONTEXT>>>.
   Only output that block when you actually read new problem-definition text.

Always start with one line: 'Looking at: <file name / what is on screen>'.
If there are no new code problems, the second line must be exactly: No new findings.
(When you just read a problem definition, add one line saying what you captured, before the context block.)

=== PROBLEM CONTEXT (captured earlier from the screen) ===
$CTX

=== OCR TEXT ===
$TEXT

=== PREVIOUS FINDINGS (most recent) ===
$PREV"

log "screen changed (similarity ${SIM}%), reviewing with $MODEL..."
RESULT=$(printf '%s' "$PROMPT" | claude -p --model "$MODEL" \
  --tools Read --allowedTools Read --strict-mcp-config --no-session-persistence 2>>"$LOG")
STATUS=$?

if [ $STATUS -ne 0 ] || [ -z "$RESULT" ]; then
  log "claude failed (exit $STATUS) - will retry"; status "review failed - retrying"
  exit 0
fi

cp "$STATE/current.txt" "$STATE/last_reviewed.txt"
status "reviewed - waiting for screen changes"

# save updated problem context if the model captured one, and strip it from the reply
NEWCTX=$(printf '%s\n' "$RESULT" | awk '/^<<<CONTEXT$/{f=1;next} /^CONTEXT>>>$/{f=0} f')
if [ -n "$NEWCTX" ]; then
  printf '%s\n' "$NEWCTX" > "$CTX_FILE"
  log "problem context updated -> output/problem_context.md"
  RESULT=$(printf '%s\n' "$RESULT" | awk '/^<<<CONTEXT$/{f=1;next} /^CONTEXT>>>$/{f=0;next} !f')
  RESULT="$RESULT
📌 Problem context updated (output/problem_context.md)"
fi

# live feed: every reply, findings or not
{ printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$(date '+%H:%M:%S')"; echo "$RESULT"; } >> "$OUT/feed.log"
if printf '%s' "$RESULT" | grep -qx "No new findings."; then
  log "reviewed: no new findings"
else
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  { echo "## $TS"; echo; echo "$RESULT"; echo; } > "$OUT/latest.md"
  { echo "## $TS"; echo; echo "$RESULT"; echo; } >> "$OUT/history.md"
  log "reviewed: NEW FINDINGS -> output/latest.md"
  osascript -e "display notification \"$(printf '%s' "$RESULT" | grep -m1 -v '^\s*$' | tr -d '\"#' | cut -c1-120)\" with title \"Live code review\"" 2>/dev/null
fi
