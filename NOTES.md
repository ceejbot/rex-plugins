# Rex plugins: findings so far

Notes from the first exploration session, 2026-11-09. The goal is a status
view for many concurrent agent sessions (Claude Code, Codex, Grok) running in
Rex: what each one is doing, which are waiting on me, and eventually a way to
answer simple prompts without switching to the pane.

Everything here was observed on a running server unless marked as a claim.
Versions: Rex server `0.0.1793645657-gd018d2` (API revision 10), Claude Code
2.1.321, Codex 0.166.0 and 0.167.0, Grok 1.0.77.

## How Rex can be extended

Rex is a server that owns sessions, windows (tabs), and blocks (panes). The
Mac app is one client. There are three interfaces to build against.

| Interface | What it is | Good for |
| --- | --- | --- |
| CLI | `rex events --json` streams changes as NDJSON; `rex api call` invokes any server method; `rex api describe` prints JSON Schema for each | An external app in any language |
| Lua | `init.lua` for key bindings and custom actions; `rex do script.lua --all` for long-running `rex.on` handlers | Small reactive automations |
| Program Status Protocol | OSC 7501, an escape sequence a program prints to report `idle`, `working`, `blocked`, `done`, or `error`, with an optional `kind` and one-line `msg` | Programs reporting their own state |

Things worth remembering:

- The raw socket protocol is not documented. The CLI is the supported
  interface, so an "app that speaks Rex" runs `rex events` as a subprocess.
- `rex.on` handlers do not run from `init.lua`. A watcher needs a
  long-running `rex do`.
- Status records belong to a pane, replace rather than accumulate, and are
  dropped by Rex when the process exits. There is no heartbeat to manage.
- A pane can hold several records: a root record plus children addressed by
  `id` (`build/test`). This is how one program reports its workers.
- Reading and answering from outside a pane both work. `program_status` (a
  block method) and `terminal.program_status_changed` (an event) give the
  state; `rex send` and `rex send-key` type into the pane.
- Floating layers exist (`session.new_layer`) but belong to one tab, so they
  do not stay visible across tabs.
- Rex's own sidebar has an "eye" view that groups panes into Blocked,
  Working, and Done with the message and its age. It truncates the message
  and leaves out panes that report no status.

Docs: <https://www.superlogical.com/rex/docs/llms.txt> indexes every page;
append `.md` to any page for Markdown. The status protocol spec is at
`/build/program-status`.

## What each agent reports

All three report through OSC 7501 with nothing installed.

| | Claude Code | Codex 0.167.0 | Grok 1.0.77 |
| --- | --- | --- | --- |
| States seen | idle, working, blocked, done | idle, working, blocked, done | idle, working, blocked, done |
| `working` message | the current step | none | a phase, e.g. "Waiting for response…" |
| `blocked` message | tool and exact command, e.g. "approve Bash: touch probe.txt" | none | the intent, e.g. "Fetch google.com response headers" |
| `done` message | a one-line summary | none | a duration, e.g. "Turn complete in 33s." |
| `done` lasts | until the next turn | not checked | until seen, then `idle` |
| Title | a short topic | task summary, spinner prefix, blinking `[ ! ] Action Required` while blocked | phase, session name, app; `⚠ Action Required` while blocked |
| Desktop notification | not seen | not seen | sent on turn completion |

Codex 0.166.0 and 0.167.0 behaved the same.

Grok's own description of its behavior (a claim, only partly observed): it
reports `error`, keeps `working` while background work it expects to finish
is still running, and sends a child record per extra session and per running
subagent, titled with the task. The setting is `[ui.notifications]
program_status`, default `"auto"`.

### Blind spots

Two dialogs wait on the user and report no status at all:

- Claude Code's workspace trust dialog ("Is this a project you trust?").
- Codex's "Hooks need review" dialog.

A pane sitting at either one looks like a plain idle pane to Rex.

### Answering prompts is per agent

The approval menus do not share a layout. "Yes" is option 1 in Claude Code
and Codex. In Grok the default is option 3, and option 1 is "always approve
everything". A switcher that answers by sending a digit would be dangerous.
Any answer-from-the-grid feature has to be written per agent, and should
re-verify the pane is still at the same prompt before sending anything.

For Codex and Grok the exact command is only on screen, not in the status
record. Reading the pane with `rex capture` does recover it.

## The prototype

`prototype/rexgrid.py` is a throwaway, now superseded by the floating panel
below: one Python file, no dependencies, display only. It draws one bordered cell per terminal pane across every
session.

    python3 prototype/rexgrid.py                  # live view, Ctrl-C to quit
    python3 prototype/rexgrid.py --once           # print one frame
    python3 prototype/rexgrid.py --shells cells   # idle shells as full cells
    python3 prototype/rexgrid.py --shells hide    # leave idle shells out

- Color by state: red blocked, magenta error, green done, yellow working,
  cyan idle, blue for a non-shell program with no status, grey for a shell.
- Each cell: name (tab label, falling back to the terminal title), app and
  directory, state and its age, up to three lines of message.
- Order: blocked, error, done first; then working; then the rest.
- Idle shells collapse to one dim line grouped by directory.
- It leaves its own pane out.

It showed the right thing live for Claude Code working and done, Codex
blocked, Grok idle, working, and blocked, and a plain `brew upgrade`.

Known rough edges:

- It polls the CLI every two seconds. A real version should hold one event
  stream open and apply events to a snapshot.
- Cells with no message (a running command, an idle Grok) are taller than
  they need to be.
- Title cleanup handles Codex's spinner and `[ ! ]` marker but not Grok's
  `⚠ Action Required - ⠴ - …` shape. This only shows in a tab with no label.
- Child records are not shown; only the most urgent record per pane is.
- Not exercised through a long session or a terminal resize.

## The floating panel

`rexgrid/` is the real version: a native macOS panel that floats above other
windows and follows across Spaces. It is a Swift package with two modules.

- `RexGridCore`: the model (`Pane`, `StatusRecord`, `Board`), event parsing
  (`RexEvent`), title cleanup (`Titles`), and the boundary to the `rex`
  command (`RexCLI`). No UI. Tested with payloads recorded from a live server.
- `RexGrid`: the panel. `Store` keeps a `Board` current; `GridView` draws it;
  `FloatingPanel` is the window.

From `rexgrid/`:

    just open     # build build/RexGrid.app and open the panel
    just quit     # or close the panel
    just test
    just dump     # print what it reads from Rex, once
    just watch    # print the board on every change, no panel

How it differs from the prototype:

- It follows `rex events --all --json` instead of polling. A status change
  is applied from the event's own payload, with no further calls.
- A layout change (a pane, tab, or session added, removed, moved, renamed)
  re-reads the layout, then describes only panes it hasn't seen. Describing
  a pane costs three `rex` calls, and every tab switch is a layout change.
- A full re-read runs at start, every 60 seconds, and after a reconnect.
- Clicking a cell shows that pane in Rex and brings Rex forward.
  `RexGrid --reveal NAME` does the same from the command line.
- A pane's name holds still across an agent's phases. Grok's title
  `Waiting for response… - fooble - grok` names the cell `fooble`.
- The panel does not take keyboard focus when clicked.

Checked: 30 tests pass; `--watch` showed a temporary tab go working, then
blocked, then disappear on exit; the app launches from Finder's bare
environment and finds `rex` in the Rex app's install location.

Clicking a cell switches Rex to that pane's tab and brings Rex forward,
confirmed by eye on 2026-11-09 once Remote Control was turned on. The app's
log is read with
`/usr/bin/log show --last 5m --predicate 'subsystem == "local.rexgrid"'`
(in zsh, plain `log` is a shell builtin).

### Size, and staying out of the way (2026-11-10)

A day of use turned up two problems. The panel sat on top of Rex while Rex
was in use, and a third session went unseen because the panel was only tall
enough for two.

- The panel's height follows its content; its width is the user's. The top
  edge holds still and the panel grows and shrinks downward. It slides up
  only if its bottom would leave the screen, and scrolls only if the content
  is taller than the screen. Dragging the height snaps back when the drag
  ends.
- While Rex is the frontmost app the panel shows only its header row, the
  colored counts. Putting the pointer on it brings the grid back, so a cell
  can still be clicked from inside Rex. It collapses 300 ms after the pointer
  leaves.
- The compact strip is half transparent (`compactAlpha` in `FloatingPanel`),
  because even one row covers text on a laptop screen. The full grid is
  always opaque.
- Both are one mechanism. `GridView` reports the height that would show
  everything, and `FloatingPanel.fit` moves the window to it. Compact is the
  content shrinking to one row.
- `PanelFrame` and `GridMetrics` in `RexGridCore` hold the arithmetic. The
  view takes its column count from `GridMetrics` and the panel takes its
  height from the same numbers.

Checked: 42 tests pass. With another app frontmost, a temporary tab running
`sleep` took the window from 448 to 578 points high and back, top edge
unmoved, read from the window server with `CGWindowListCopyWindowInfo` and
matching the app's log. With Rex frontmost the window server held the panel
at 28 points high, top edge unmoved, and at 448 again once another app came
forward.

Confirmed by eye the same day: the collapse to the title bar row, the dimmed
strip (the window server reported its alpha as 0.5), the return to full
opacity, and the grid reappearing when another app comes forward. Nobody has
reported on whether the hover flaps at the panel's edge. The log has
a `panel` category for this: every content height, every frame the window
took, every change of frontmost app, every hover.

Things learned building that:

- A lazy grid knows its height only from rows it has drawn. In a collapsed
  panel it has drawn none, so its measured height can't be what the panel
  grows back to. The height is computed from the cell count.
- The stack's height less the scroll view's height is everything that isn't
  grid, and it is the same at any window size. That gives an ideal height
  that doesn't move while the window resizes toward it.
- `NSWindow.inLiveResize` is true during AppKit's own animated `setFrame`,
  not only during a user's drag. The panel resizes without animation so the
  flag means one thing.
- `NSHostingView` holds its window to the content's minimum size unless
  `sizingOptions` is emptied. That minimum was 56 points for a 28-point
  header, and a panel asking for 28 never got there.
- SwiftUI lays a view out and reports its geometry while the window is
  still being built. A callback into an object that will hold the window
  has to keep what arrives early.

Things learned building it:

- Rex keeps two kinds of state, and showing a pane needs both changed.
  `rex focus -s SESSION BLOCK` changes the session on the server: its active
  tab and focused pane. The app does not follow that. Which tab the app
  displays is the app's own state, changed only by a client action,
  `rex do session.select session_id=… window_id=…`.
- The app refuses client actions with "Rex.app is not accepting actions"
  unless Remote Control is on: Rex Settings › Server › Client Info. With it
  off, nothing outside the app can switch its tab. The panel recognizes the
  refusal and says so in an orange line under its header.
- A first version got this wrong twice. It checked the server's
  `active_window_id` after `rex focus`, saw it change, and took that as the
  tab switching. Only the person looking at the app can confirm a tab
  switch; nothing in the API reports what the app is displaying.
- The first click on a window that isn't key only selects the window. A
  panel that is never key gets no clicks at all unless its hosting view
  returns true from `acceptsFirstMouse`.
- `NSRunningApplication.activate()` does nothing when the caller is not the
  active app, and a non-activating panel never is. Opening the app's bundle
  through `NSWorkspace.openApplication` brings it forward reliably.

- An app launched from Finder has no `rex` on its PATH. The CLI lives at
  `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex`.
- Every `rex` CLI call joins and leaves as a client, and each one produces
  events. The polling prototype alone generated about nine of these a second.
- Child records arrive as their own `program_status_changed` events with an
  `id` such as `w1/sub`. Clearing a parent removes its children in one
  `program_status_removed` event listing every id. On exit Rex removes the
  root record with reason `child_exited`.
- An agent in a pane without `REX_SESSION` and `REX_BLOCK` in its environment
  appears to report nothing. One Claude Code pane in that condition showed up
  as a plain running program. Not confirmed as the cause.

## Decisions made

- The view is a native floating panel, not tied to a terminal.
- Fixed-size cells for anything that reports a status, so the grid doesn't
  reflow as messages change. Compact treatment for idle shells.
- The titles are worth keeping prominent.

## Open questions

- Whether running commands with no status get a short cell or a compact line
  like the shells.
- How to show child records once an agent uses them.
- Interaction: jump to a pane, peek at its last lines, answer a prompt.
- Whether the blind-spot dialogs can be detected, for example by reading the
  screen of panes whose foreground program is an agent with no record.

## Other ideas noted

- An `init.lua` action that jumps to the longest-waiting blocked pane.
- A Lua script that labels each tab with its directory and state.
- macOS notifications on `blocked` or `done` for panes not in view.
- A shell function that wraps `cargo test` or a deploy so it reports status.
- One switcher spanning several Rex hosts (`rex.servers()` in Lua).

## Aside: permissions

Part of the original pain was sessions waiting on trivial permission
questions. During this session cc-allow was retired in favor of Claude
Code's native permission rules in `~/.claude/settings.json`, running in auto
mode. A replay of 30 days of real tool calls showed cc-allow allowing about
92% on first sight, so it was not the main source of prompts; the reason to
retire it was to have one enforcement engine and to stop its background
rule-writer from producing broken session configs.

The native rules pre-allow all web fetches and reads and writes under
Claude's tmp directories, and deny recursive `rm`, forced pushes, hard
resets, and `sed -i` by text pattern. Text patterns miss unusual spellings
(`rm -vfr`, `/bin/rm`, a script). The sandbox, which confines shell writes
to the working directory at the OS level, is the real protection against a
stray `rm -r` and is not enabled yet.
