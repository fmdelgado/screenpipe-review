# Multi-Scroll Complete-Definition Capture Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically accumulate scrolled pages of multi-screen problems into a single multi-image Claude call and wait for the complete problem definition before outputting a full answer.

**Architecture:** Extend `solver_stream.py` to accept repeatable `--image` arguments and emit labeled multi-image `stream-json` blocks. Add a rolling `$STATE/pages/` buffer, `1.2s` scroll-settle capture loop, domain-overlap auto-reset, and completeness-check prompt (`⬇ Scroll down` + `state/awaiting_more`) in `review.sh`, with matching footer status and `[c]` reset in `live-review`.

**Tech Stack:** Python 3 (stdlib), Bash (macOS `/bin/bash` 3.2), Swift `helper`, Claude Code CLI (`claude -p`).

---

### Task 1: Repeatable Multi-Image Support in `solver_stream.py`
- Modify `solver_stream.py`: change `--image` to `action="append", default=[]`, emit labeled image blocks when `len(images) > 1`, single image block when `len(images) == 1`.
- Add failing test in `test.sh` verifying 3 `--image` args produce 3 `"type": "image"` blocks with `Screenshot 1 of 3` … `Screenshot 3 of 3` labels, verify RED -> implement -> verify GREEN.

### Task 2: Scroll-Settle Buffer, Auto-Reset & Completeness Gate in `review.sh`
- Add `CAPTURE_CMD` hook (or sequence-aware `CAPTURE_IMAGE`) + `SCROLL_SETTLE`, `MAX_PAGES`, `PAGE_IDLE_RESET_SECS`, `$STATE/pages/`, and `$STATE/awaiting_more` in `review.sh`.
- Add completeness-check prompt instructions for automatic runs vs immediate-solve instruction for `FORCE_REVIEW=1`.
- Add Task 8 tests in `test.sh`:
  - Rapid 3-page scroll during settle produces **1** Claude call with **3** attached images.
  - `⬇ Scroll down` response sets `state/awaiting_more=1` and preserves Page 1 even when Page 2 has disjoint words (denominator table).
  - Complete response clears `state/awaiting_more=0`, and switching to an unrelated screen auto-resets `$STATE/pages/` to 1 image.
  - `FORCE_REVIEW=1` bypasses scroll-settle and tells Claude to solve immediately without asking to scroll.

### Task 3: Footer Status & `[c]` Cleanup in `live-review` + `README.md`
- Update `live-review` to clear `$STATE/pages/` and `$STATE/awaiting_more` on startup and `[c]`, and show `◌ capturing ...` on the dimmed footer.
- Update `README.md` to document automatic multi-scroll capture and completeness gating.
- Verify `[c]` clears `state/pages/` in `test.sh`.

### Task 4: Full Suite & Real Live Multi-Scroll End-to-End Verification
- Run `./test.sh` (0 failures).
- Run real `claude -p` end-to-end test on a 2-scroll data-quality work sample (Page 1 with R7 cut off + missing denominator table -> expects `⬇ Scroll down` & `awaiting_more=1` -> Page 2 with R7 + denominator table + question -> expects single complete, accurate solution combining both pages!), plus a single-screen complete quiz (expects immediate direct solution with no scroll prompt).
