#!/usr/bin/env python3
"""rexgrid: a throwaway prototype of a color-coded status grid for Rex panes.

One cell per terminal pane across every Rex session. Each cell shows what the
pane is, the state its program reports (OSC 7501), how long it has been in
that state, and what it is doing or waiting for.

    python3 rexgrid.py            # live view, Ctrl-C to quit
    python3 rexgrid.py --once     # print one frame and exit
    python3 rexgrid.py -n 5       # refresh every 5 seconds

This polls the `rex` CLI. A real version would hold one event stream open
instead; polling keeps the prototype to one file with no dependencies.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

TERMINAL = "com.superlogical.terminal"
SHELLS = {"fish", "zsh", "bash", "sh", "nu", "dash"}

# state -> (sort rank, ANSI color, label). Rank puts what needs you first.
STATES = {
    "blocked": (0, "1;31", "BLOCKED"),
    "error": (1, "1;35", "ERROR"),
    "done": (2, "32", "DONE"),
    "working": (3, "33", "WORKING"),
    "idle": (4, "36", "IDLE"),
    "running": (5, "34", "RUNNING"),  # no status record, but not a shell
    "shell": (6, "90", "SHELL"),
}
CELL_W = 40  # outer width of a cell, borders included
MSG_LINES = 3


def rex(*args):
    """Run a rex command that prints JSON; None when it fails."""
    try:
        out = subprocess.run(["rex", *args], capture_output=True, text=True, timeout=10)
        return json.loads(out.stdout) if out.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def list_panes():
    panes = []
    for session in (rex("ls", "--json") or {}).get("sessions", []):
        sid = session["session_id"]
        view = rex("window", "ls", "-s", sid, "--json") or {}
        for window in view.get("windows", []):
            for layer in window.get("layers", []):
                for block in layer.get("blocks", []):
                    if block.get("creator_name") == TERMINAL:
                        panes.append({
                            "session_id": sid,
                            "session": session.get("label") or "",
                            "tab": window.get("label") or "",
                            "block_id": block["block_id"],
                        })
    return panes


def steady(title):
    """Drop the animated prefixes programs put on titles, so cells don't flicker.

    Codex leads its title with a braille spinner frame while working and with
    a blinking "[ ! ]" / "[ . ]" marker while it waits for approval.
    """
    return re.sub(r"^(?:[⠀-⣿]|\[ [.!] \])\s+", "", title)


def describe(pane):
    """Fill in a pane's reported status, title, and foreground process."""
    call = ("block", "call", "-s", pane["session_id"], "-b", pane["block_id"])
    records = (rex(*call, "program_status") or {}).get("records", [])
    title = steady((rex(*call, "title") or {}).get("title") or "")
    fg = (rex(*call, "process") or {}).get("foreground") or {}

    # A pane can hold several records (a program and its workers). Show the
    # one that most needs attention.
    record = min(records, key=lambda r: STATES.get(r.get("state"), (9,))[0], default=None)
    proc = fg.get("name") or ""
    if record:
        state = record.get("state", "idle")
        app = record.get("effective_app") or record.get("app") or proc
    elif proc in SHELLS or not proc:
        state, app = "shell", proc or "shell"
    else:
        state, app = "running", proc

    # Rex names untitled tabs "Window 1a2b3c4d"; the terminal title says more.
    name = pane["tab"] if pane["tab"] and not pane["tab"].startswith("Window ") else title
    msg = (record or {}).get("msg") or ""
    if record and record.get("kind"):
        msg = f"[{record['kind']}] {msg}"
    if not msg and title != name:
        msg = title

    pane.update(
        state=state,
        app=app,
        name=name or app,
        dir=os.path.basename((fg.get("cwd") or "").rstrip("/")),
        msg=msg,
        since=(record or {}).get("updated_at"),
        progress=(record or {}).get("progress"),
    )
    return pane


def age(stamp):
    if not stamp:
        return ""
    try:
        secs = (datetime.now(timezone.utc) - datetime.fromisoformat(stamp)).total_seconds()
    except ValueError:
        return ""
    for limit, div, unit in ((90, 1, "s"), (5400, 60, "m"), (129600, 3600, "h")):
        if secs < limit:
            return f"{int(secs // div)}{unit}"
    return f"{int(secs // 86400)}d"


def clean(text):
    return "".join(ch if ch.isprintable() else " " for ch in text)


def fit(text, width):
    text = clean(text)
    return text[: width - 1] + "…" if len(text) > width else text.ljust(width)


def cell(pane):
    """Render one pane as a list of equal-width, colored lines."""
    _, color, label = STATES[pane["state"]]
    inner = CELL_W - 4
    paint = lambda s, c=color: f"\x1b[{c}m{s}\x1b[0m"
    side = paint("│")

    badge = label + (f" {pane['progress']}%" if pane.get("progress") is not None else "")
    when = age(pane["since"])
    status = badge + " " * max(1, inner - len(badge) - len(when)) + when
    where = " · ".join(p for p in (pane["app"], pane["dir"]) if p)
    msg = textwrap.wrap(clean(pane["msg"]), inner)[:MSG_LINES]
    msg += [""] * (MSG_LINES - len(msg))

    rows = [
        paint(fit(pane["name"], inner), "1"),
        paint(fit(where, inner), "2"),
        paint(fit(status, inner)),
        *(fit(line, inner) for line in msg),
    ]
    top = paint("╭" + "─" * (CELL_W - 2) + "╮")
    bottom = paint("╰" + "─" * (CELL_W - 2) + "╯")
    return [top, *(f"{side} {row} {side}" for row in rows), bottom]


def shell_strip(shells, width):
    """Idle shells as one dim wrapped line: a directory each, with a count."""
    dirs = {}
    for p in shells:
        # Directory names and titles are whatever is on disk or a program
        # set; never pass their control characters through to the terminal.
        key = clean(p["dir"] or p["name"])
        dirs[key] = dirs.get(key, 0) + 1
    chips = [d + (f" ×{n}" if n > 1 else "") for d, n in sorted(dirs.items())]
    text = "shells  " + "  ·  ".join(chips)
    return [f" \x1b[90m{line}\x1b[0m" for line in textwrap.wrap(text, max(20, width - 2))]


def frame(panes, width, shells="strip"):
    panes = sorted(panes, key=lambda p: (STATES[p["state"]][0], p["name"].lower()))
    idle_shells = [p for p in panes if p["state"] == "shell"]
    if shells != "cells":
        panes = [p for p in panes if p["state"] != "shell"]
    counts = {}
    for p in panes + (idle_shells if shells != "cells" else []):
        counts[p["state"]] = counts.get(p["state"], 0) + 1
    summary = "  ".join(
        f"\x1b[{STATES[s][1]}m{n} {STATES[s][2].lower()}\x1b[0m"
        for s, n in sorted(counts.items(), key=lambda kv: STATES[kv[0]][0])
    )
    lines = [f" {summary}   \x1b[2m{time.strftime('%H:%M:%S')}\x1b[0m", ""]
    cols = max(1, width // (CELL_W + 1))
    cells = [cell(p) for p in panes]
    for start in range(0, len(cells), cols):
        row = cells[start:start + cols]
        lines.extend(" ".join(parts) for parts in zip(*row))
    if shells == "strip" and idle_shells:
        lines.extend(shell_strip(idle_shells, width))
    return lines


def snapshot(skip=None):
    """Describe every pane, leaving out `skip` (the grid's own pane)."""
    panes = [p for p in list_panes() if p["block_id"] != skip]
    with ThreadPoolExecutor(8) as pool:
        return list(pool.map(describe, panes))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--once", action="store_true", help="print one frame and exit")
    ap.add_argument("-n", "--interval", type=float, default=2.0, help="seconds between refreshes")
    ap.add_argument("--shells", choices=("strip", "cells", "hide"), default="strip",
                    help="idle shells as one compact line (default), full cells, or not at all")
    args = ap.parse_args()

    if args.once:
        print("\n".join(frame(snapshot(), shutil.get_terminal_size().columns, args.shells)))
        return

    sys.stdout.write("\x1b[?1049h\x1b[?25l")  # alternate screen, hide cursor
    try:
        while True:
            size = shutil.get_terminal_size()
            panes = snapshot(skip=os.environ.get("REX_BLOCK"))
            lines = frame(panes, size.columns, args.shells)[: size.lines]
            # Clear to end of each line so a shrinking frame leaves no debris.
            sys.stdout.write("\x1b[H" + "\x1b[K\n".join(lines) + "\x1b[K\x1b[J")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
