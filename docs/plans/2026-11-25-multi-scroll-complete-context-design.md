# Multi-Scroll Complete-Definition Capture Design

**Date:** 2026-11-25  
**Status:** Approved

## Goal

Enable hands-free solving of long, multi-screen problem definitions (such as data-quality work samples, long coding specs, or multi-part assessments) by automatically accumulating scrolled pages into a single multi-image Claude call and ensuring Claude has the complete problem definition before committing to a full answer.

## Architecture

1. **Multi-Image Payload (`solver_stream.py`):**
   - Accept repeatable `--image <path>` flags (`action="append"`).
   - When multiple pages are attached, interleave concise chronological labels (`Screenshot 1 of N (earlier scroll):`, …, `Screenshot N of N (current view):`) before each inline base64 JPEG block in `--input-format stream-json`.
   - Claude sees the exact raw visual tables, numbers, and text from every scroll at full fidelity (no summary compression loss).

2. **Rolling Page Buffer & Scroll-Settle Capture (`review.sh`):**
   - Maintain `$STATE/pages/` (`page_001.jpg`, … up to `MAX_PAGES=5`, downscaled to `1600px` JPEG).
   - **Scroll-settle debounce (`SCROLL_SETTLE=1.2s`):** when a meaningful screen change is detected on a non-forced cycle, capture the first page, display `◌ capturing (1 page)...`, and wait `1.2s`. If the screen moves again (`vdiff-cells >= 15`), append the new page without calling Claude yet and wait another `1.2s` until scrolling settles (or `MAX_PAGES` is reached). Then make **one** Claude call with all accumulated pages.
   - **Auto-reset between unrelated problems:** while `state/awaiting_more=1`, every new scroll appends regardless of word overlap. Once solved (`awaiting_more=0`), switching to a screen with `<15%` non-stopword token overlap against the last page (or `>90s` idle) automatically resets `$STATE/pages/`.
   - **Manual override (`[Space]` / `FORCE_REVIEW=1`):** skips the settle wait, sends all currently accumulated pages + current view, and instructs Claude to solve immediately with what is captured.

3. **Completeness Gate Before Answering (`review.sh`):**
   - On automatic runs, instruct Claude to check across all attached screenshots + `SAVED CONTEXT` whether critical parts of the problem definition are visibly cut off or referenced as below/above (e.g., a truncated table row, a referenced denominator table, or unseen task questions).
   - If incomplete, Claude outputs only:
     ```
     ⬇ Scroll down to capture the rest
     Missing: <specific missing parts>
     (Press Space to solve now with what's captured)
     ```
     plus silent `<<<CONTEXT ... CONTEXT>>>`. `review.sh` sets `state/awaiting_more=1` and keeps `$STATE/pages/` intact.
   - Once the remaining scroll(s) arrive, Claude receives all pages together, replaces the screen with the complete solution, and resets `state/awaiting_more=0`.

4. **UI & Cleanup (`live-review`):**
   - Display `◌ capturing (N pages)...` on the dimmed footer during scroll-settle.
   - Reset `$STATE/pages/` and `$STATE/awaiting_more` on startup and on `[c]` clear.
