#!/usr/bin/env python3
"""Summarise a Claude Code JSONL transcript from a beam as Markdown.

Reads the transcript on stdin. Mirrors the VS Code extension's Agent Activity
and Agent Events panels: token usage is de-duplicated by message id (one API
response is split across several JSONL lines that share it), tool calls are
matched to their results by tool_use_id, and the tail of the conversation is
rendered chronologically.

Usage: activity.py [--beam ID] [--path TRANSCRIPT] [--events N] [--tools N]
"""
import argparse
import json
import sys
from datetime import datetime, timezone

# $/M tokens: input, cache write, cache read, output — rough public list prices.
COST_PER_MILLION = {
    "opus": (15.0, 18.75, 1.5, 75.0),
    "sonnet": (3.0, 3.75, 0.3, 15.0),
    "haiku": (0.8, 1.0, 0.08, 4.0),
}


def estimate_cost(model, tokens_in, cache_write, cache_read, tokens_out):
    key = next((k for k in COST_PER_MILLION if k in model), "sonnet")
    in_rate, cw_rate, cr_rate, out_rate = COST_PER_MILLION[key]
    return (tokens_in * in_rate + cache_write * cw_rate + cache_read * cr_rate + tokens_out * out_rate) / 1_000_000


def fmt_num(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K"
    return str(n)


def fmt_time(ts):
    if not ts:
        return "        "
    try:
        text = ts.replace("Z", "+00:00")
        dt = datetime.fromisoformat(text).astimezone()
        return dt.strftime("%H:%M:%S")
    except ValueError:
        return ts[:8]


def summarize_args(inp):
    if not isinstance(inp, dict):
        return ""
    for key in ("file_path", "path"):
        if inp.get(key):
            return str(inp[key]).rsplit("/", 1)[-1]
    for key in ("command", "query", "pattern", "description", "prompt"):
        if inp.get(key):
            val = str(inp[key]).replace("\n", " ")
            return val if len(val) <= 70 else val[:70] + "…"
    return ""


def one_line(text, limit=110):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit] + "…"


def result_text(block):
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def parse(lines):
    tokens_in = tokens_out = cache_read = cache_write = 0
    model = ""
    messages = 0
    counted_usage = set()
    counted_msgs = set()
    tool_calls = []
    pending = {}
    events = []
    first_ts = last_ts = None
    session_id = None
    cwd = None

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = entry.get("timestamp")
        if ts:
            first_ts = first_ts or ts
            last_ts = ts
        session_id = session_id or entry.get("sessionId")
        cwd = cwd or entry.get("cwd")

        msg = entry.get("message")
        if not isinstance(msg, dict):
            continue
        if msg.get("model"):
            model = msg["model"]

        msg_id = msg.get("id")
        usage = msg.get("usage")
        if usage and msg_id and msg_id not in counted_usage:
            counted_usage.add(msg_id)
            tokens_in += usage.get("input_tokens", 0) or 0
            tokens_out += usage.get("output_tokens", 0) or 0
            cache_read += usage.get("cache_read_input_tokens", 0) or 0
            cache_write += usage.get("cache_creation_input_tokens", 0) or 0

        etype = entry.get("type")
        content = msg.get("content")
        is_tool_result = "toolUseResult" in entry or (
            isinstance(content, list)
            and content
            and all(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
        )
        if etype == "user" and not is_tool_result:
            messages += 1
        elif etype == "assistant" and msg_id and msg_id not in counted_msgs:
            counted_msgs.add(msg_id)
            messages += 1

        if isinstance(content, str):
            if etype == "user" and content.strip():
                events.append((ts, "user", one_line(content)))
            continue
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text" and block.get("text", "").strip():
                role = "user" if etype == "user" else "assistant"
                events.append((ts, role, one_line(block["text"])))
            elif btype == "tool_use":
                call = {"tool": block.get("name", "?"), "args": summarize_args(block.get("input")), "ok": None}
                tool_calls.append(call)
                if block.get("id"):
                    pending[block["id"]] = call
                events.append((ts, "tool", f"{call['tool']}  {call['args']}".rstrip()))
            elif btype == "tool_result":
                target = pending.pop(block.get("tool_use_id"), None)
                if target is not None:
                    target["ok"] = not block.get("is_error", False)
                    text = result_text(block)
                    target["result"] = one_line(text, 90)
                    if block.get("is_error"):
                        events.append((ts, "error", one_line(text)))

    return {
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "cache_read": cache_read,
        "cache_write": cache_write,
        "model": model or "unknown",
        "messages": messages,
        "tool_calls": tool_calls,
        "events": events,
        "first_ts": first_ts,
        "last_ts": last_ts,
        "session_id": session_id,
        "cwd": cwd,
    }


def render(summary, beam, path, max_events, max_tools):
    s = summary
    cost = estimate_cost(s["model"], s["tokens_in"], s["cache_write"], s["cache_read"], s["tokens_out"])
    total = s["tokens_in"] + s["tokens_out"] + s["cache_read"] + s["cache_write"]
    now = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")

    out = [f"# Agent Activity — {beam or 'beam'}", ""]
    out.append(f"Generated {now}.")
    if path:
        out.append(f"Transcript: `{path}`")
    if s["session_id"]:
        out.append(f"Session: `{s['session_id']}`")
    if s["cwd"]:
        out.append(f"Working directory: `{s['cwd']}`")
    if s["first_ts"] and s["last_ts"]:
        out.append(f"Span: {fmt_time(s['first_ts'])} → {fmt_time(s['last_ts'])} (local time)")
    out += ["", "## Session", ""]
    out.append("| Metric | Value |")
    out.append("|---|---|")
    out.append(f"| Model | {s['model']} |")
    out.append(f"| Messages | {s['messages']} |")
    out.append(f"| Tokens in | {fmt_num(s['tokens_in'])} ({fmt_num(s['cache_read'])} cache read, {fmt_num(s['cache_write'])} cache write) |")
    out.append(f"| Tokens out | {fmt_num(s['tokens_out'])} |")
    out.append(f"| Total tokens | {fmt_num(total)} |")
    out.append(f"| Estimated cost | ${cost:.4f} |")
    out.append(f"| Tool calls | {len(s['tool_calls'])} |")

    tools = s["tool_calls"][-max_tools:]
    out += ["", f"## Recent tool calls (last {len(tools)} of {len(s['tool_calls'])})", ""]
    if not tools:
        out.append("_none_")
    for call in reversed(tools):
        status = "✓" if call["ok"] else ("✗" if call["ok"] is False else "…")
        line = f"- {status} **{call['tool']}** {call['args']}".rstrip()
        if call.get("result") and call["ok"] is False:
            line += f"  — {call['result']}"
        out.append(line)

    events = s["events"][-max_events:]
    out += ["", f"## Recent events (last {len(events)} of {len(s['events'])})", ""]
    if not events:
        out.append("_none_")
    labels = {"user": "USER ", "assistant": "CLAUDE", "tool": "TOOL ", "error": "ERROR"}
    for ts, kind, text in events:
        out.append(f"    {fmt_time(ts)}  {labels.get(kind, kind):6} {text}")
    out.append("")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--beam", default="")
    parser.add_argument("--path", default="")
    parser.add_argument("--events", type=int, default=40)
    parser.add_argument("--tools", type=int, default=30)
    args = parser.parse_args()
    summary = parse(sys.stdin)
    sys.stdout.write(render(summary, args.beam, args.path, args.events, args.tools))


if __name__ == "__main__":
    main()
