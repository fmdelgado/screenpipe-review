#!/usr/bin/env python3
"""Stream multimodal screenshot prompts through `claude -p --output-format stream-json`.

Sends the downscaled screenshot inline via `--input-format stream-json` (zero Read
round-trip), streams only the clean solution text live to stdout, silently strips and
saves any `<<<CONTEXT ... CONTEXT>>>` block, and falls back seamlessly to plain-text
output for stubs or error responses.
"""
import argparse
import base64
import json
import os
import signal
import subprocess
import sys
import tempfile

MARKER = "<<<CONTEXT"


def split_context(text: str):
    lines = text.splitlines()
    out_lines = []
    ctx_lines = []
    in_ctx = False
    for line in lines:
        stripped = line.strip()
        if stripped == "<<<CONTEXT":
            in_ctx = True
            continue
        if stripped == "CONTEXT>>>":
            in_ctx = False
            continue
        if in_ctx:
            ctx_lines.append(line)
        else:
            out_lines.append(line)
    return "\n".join(out_lines).strip(), "\n".join(ctx_lines).strip()


def write_text(path: str, content: str):
    if not path:
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


class StreamEmitter:
    def __init__(
        self,
        live: bool,
        divider_time: str,
        streaming_flag: str,
        clear_on_start: bool = False,
        header_text: str = "",
    ):
        self.live = live
        self.divider_time = divider_time
        self.streaming_flag = streaming_flag
        self.clear_on_start = clear_on_start
        self.header_text = header_text
        self.started = False
        self.in_context = False
        self.pending = ""

    def _begin_if_needed(self):
        if self.started or not self.live:
            return
        self.started = True
        if self.streaming_flag:
            try:
                with open(self.streaming_flag, "w", encoding="utf-8") as f:
                    f.write("1")
            except OSError:
                pass
        if self.clear_on_start:
            sys.stdout.write("\033[H\033[2J\033[3J")
            if self.header_text:
                sys.stdout.write(f"\033[2m{self.header_text}\033[0m\n\n")
        else:
            sys.stdout.write("\r\033[K")
            if self.divider_time:
                sys.stdout.write(f"\n\033[2m─── {self.divider_time} ───\033[0m\n")
        sys.stdout.flush()

    def _write(self, chunk: str):
        if not self.live or not chunk:
            return
        self._begin_if_needed()
        sys.stdout.write(chunk)
        sys.stdout.flush()

    def show_status(self, message: str):
        if not self.live or self.started:
            return
        sys.stdout.write(f"\r\033[K\033[2m◌ {message}\033[0m")
        sys.stdout.flush()

    def emit_delta(self, delta: str):
        if not self.live or self.in_context or not delta:
            return
        self.pending += delta
        if not self.started:
            self.pending = self.pending.lstrip("\r\n")
            if not self.pending:
                return

        if MARKER in self.pending:
            idx = self.pending.find(MARKER)
            before = self.pending[:idx].rstrip("\r\n")
            if before:
                self._write(before)
            self.pending = ""
            self.in_context = True
            return

        # Hold trailing newlines and any partial prefix of "<<<CONTEXT" so neither
        # marker characters nor blank lines preceding <<<CONTEXT leak to the terminal.
        i = len(self.pending)
        while i > 0 and self.pending[i - 1] in "\r\n":
            i -= 1
        tail_start = i
        max_k = min(len(MARKER) - 1, tail_start)
        for k in range(max_k, 0, -1):
            if self.pending[tail_start - k : tail_start] == MARKER[:k]:
                tail_start -= k
                while tail_start > 0 and self.pending[tail_start - 1] in "\r\n":
                    tail_start -= 1
                break

        if tail_start > 0:
            self._write(self.pending[:tail_start])
            self.pending = self.pending[tail_start:]

    def finish(self):
        if not self.live:
            return
        if not self.in_context and self.pending:
            rem = self.pending.rstrip("\r\n")
            if rem:
                self._write(rem)
            self.pending = ""
        if self.started:
            sys.stdout.write("\n")
            sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--claude", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--image", action="append", default=[])
    ap.add_argument("--system-prompt-file", required=True)
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--web", default="1")
    ap.add_argument("--status-file", default="")
    ap.add_argument("--streaming-flag", default="")
    ap.add_argument("--reply-out", required=True)
    ap.add_argument("--context-out", required=True)
    ap.add_argument("--err-out", required=True)
    ap.add_argument("--live-stream", default="0")
    ap.add_argument("--clear-on-start", default="0")
    ap.add_argument("--header-text", default="")
    ap.add_argument("--divider-time", default="")
    ap.add_argument("--add-dir", default="")
    ap.add_argument("--cwd", default="")
    args = ap.parse_args()

    live = args.live_stream == "1"
    clear_on_start = args.clear_on_start == "1"
    web_on = args.web == "1"

    with open(args.system_prompt_file, "r", encoding="utf-8") as f:
        system_prompt = f.read()
    with open(args.prompt_file, "r", encoding="utf-8") as f:
        prompt_text = f.read()

    content = []
    valid_images = [p for p in (args.image or []) if p and os.path.isfile(p)]
    total_imgs = len(valid_images)
    for idx, img_path in enumerate(valid_images, start=1):
        if total_imgs > 1:
            if idx == 1:
                label = f"Screenshot {idx} of {total_imgs} (earlier scroll):"
            elif idx == total_imgs:
                label = f"Screenshot {idx} of {total_imgs} (current view):"
            else:
                label = f"Screenshot {idx} of {total_imgs}:"
            content.append({"type": "text", "text": label})
        lower = img_path.lower()
        media_type = "image/jpeg" if lower.endswith((".jpg", ".jpeg")) else "image/png"
        with open(img_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("ascii")
        content.append(
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": media_type,
                    "data": b64,
                },
            }
        )
    content.append({"type": "text", "text": prompt_text})
    payload = json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n"

    cmd = [
        args.claude,
        "-p",
        "--model",
        args.model,
        "--safe-mode",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--system-prompt",
        system_prompt,
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
    ]
    if args.add_dir:
        cmd += ["--add-dir", args.add_dir]
    if web_on:
        cmd += ["--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch"]
    else:
        cmd += ["--tools", ""]

    emitter = StreamEmitter(
        live=live,
        divider_time=args.divider_time,
        streaming_flag=args.streaming_flag,
        clear_on_start=clear_on_start,
        header_text=args.header_text,
    )
    proc = None

    def cleanup_flag():
        if args.streaming_flag:
            try:
                os.remove(args.streaming_flag)
            except OSError:
                pass

    def handle_sig(signum, _frame):
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=1)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        cleanup_flag()
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    err_tmp = tempfile.TemporaryFile(mode="w+", encoding="utf-8")
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=err_tmp,
            text=True,
            bufsize=1,
            cwd=args.cwd or None,
        )
        try:
            proc.stdin.write(payload)
            proc.stdin.close()
        except BrokenPipeError:
            pass

        json_mode = None
        raw_chunks = []
        plain_lines = []
        is_error = False
        err_detail = ""
        saw_tool_since_text = False

        assert proc.stdout is not None
        for line in proc.stdout:
            if json_mode is None:
                stripped = line.strip()
                if not stripped:
                    continue
                if stripped.startswith("{"):
                    try:
                        obj = json.loads(stripped)
                        if isinstance(obj, dict) and "type" in obj:
                            json_mode = True
                        else:
                            json_mode = False
                    except json.JSONDecodeError:
                        json_mode = False
                else:
                    json_mode = False

            if not json_mode:
                plain_lines.append(line)
                continue

            stripped = line.strip()
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError:
                continue

            ev_outer = obj.get("type")
            if ev_outer == "stream_event":
                ev = obj.get("event") or {}
                ev_type = ev.get("type")
                if ev_type == "message_start":
                    if saw_tool_since_text and emitter.started:
                        raw_chunks.append("\n\n")
                        emitter.emit_delta("\n\n")
                        saw_tool_since_text = False
                elif ev_type == "content_block_start":
                    cb = ev.get("content_block") or {}
                    if cb.get("type") in ("tool_use", "server_tool_use"):
                        tname = str(cb.get("name") or "")
                        saw_tool_since_text = True
                        if tname in ("WebSearch", "WebFetch") or "web" in tname.lower():
                            write_text(args.status_file, "searching web...")
                            emitter.show_status("searching web... · web ON")
                elif ev_type == "content_block_delta":
                    delta = ev.get("delta") or {}
                    if delta.get("type") == "text_delta":
                        txt = delta.get("text") or ""
                        if txt:
                            raw_chunks.append(txt)
                            emitter.emit_delta(txt)
            elif ev_outer == "result":
                if obj.get("is_error"):
                    is_error = True
                    err_detail = str(obj.get("result") or obj.get("error") or "claude returned an error")
                elif not raw_chunks and obj.get("result"):
                    txt = str(obj["result"])
                    raw_chunks.append(txt)
                    emitter.emit_delta(txt)

        rc = proc.wait()
        err_tmp.seek(0)
        stderr_text = err_tmp.read().strip()

        if json_mode:
            emitter.finish()
            if is_error or rc != 0:
                detail = err_detail or stderr_text or f"exit {rc}"
                write_text(args.err_out, detail)
                write_text(args.reply_out, "")
                write_text(args.context_out, "")
                sys.exit(rc if rc != 0 else 1)
            raw_text = "".join(raw_chunks)
        else:
            plain_text = "".join(plain_lines)
            if rc != 0:
                detail = plain_text.strip() or stderr_text or f"exit {rc}"
                write_text(args.err_out, detail)
                write_text(args.reply_out, "")
                write_text(args.context_out, "")
                sys.exit(rc)
            raw_text = plain_text
            clean_preview, _ = split_context(raw_text)
            if live and clean_preview:
                emitter.emit_delta(clean_preview)
                emitter.finish()

        clean_reply, new_ctx = split_context(raw_text)
        write_text(args.reply_out, clean_reply)
        write_text(args.context_out, new_ctx)
        write_text(args.err_out, "")
        if not clean_reply:
            write_text(args.err_out, stderr_text or "empty response")
            sys.exit(1)
    finally:
        err_tmp.close()
        cleanup_flag()


if __name__ == "__main__":
    main()
