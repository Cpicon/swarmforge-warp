# SwarmForge → Warp integration: implementation plan

## Problem
[SwarmForge](https://github.com/unclebob/swarm-forge) is a tmux-based multi-agent orchestration tool. Inside the Warp terminal on macOS, its terminal auto-detection opens one macOS Terminal.app window per agent. Goal: all agent sessions appear as split panes in a **single Warp tab**, via a maintainable overlay repo (`Cpicon/swarmforge-warp`) that treats upstream SwarmForge as a pinned install-time dependency.

## Verified constraints (ground truth — established by live experiments on this machine; do NOT re-litigate)
1. Warp Tab Configs (`~/.warp/tab_configs/*.toml`) support a single tab with nested-split panes, per-pane startup `commands`, and open in the **current window** when clicked in the sidebar `+` menu. Confirmed working with `tmux attach` panes (TUIs render fine).
2. The `warp://launch/` URI scheme is **non-functional** in current Warp Stable (tested exhaustively). Opening the swarm tab therefore requires one manual click: sidebar `+` → config name. Do not attempt URI/AppleScript automation — Warp has no AppleScript dictionary and no pane query/close API.
3. Because there is no pane query API, SwarmForge's window watchdog must stay disabled: the adapter reports `terminal_backend_tracks_windows` = false. This is a supported degraded mode upstream (see `open-terminal-surfaces!` in `swarmforge.bb`).
4. Pane commands MUST use `exec tmux -S <socket> attach-session -t <session>`: when the swarm shuts down, `exec` panes self-close cleanly. Without `exec`, panes leave red `[server exited]` blocks and a warning badge on the tab.
5. SwarmForge creates ALL tmux sessions and writes `$WORKING_DIR/.swarmforge/sessions.tsv` BEFORE the first `terminal_open_session` call. So on the first call the adapter can read the full role list and generate one complete tab config.
6. Adapter subprocess env: the caller (babashka `process/sh` via `zsh -c`) sets `SCRIPT_DIR`, `WORKING_DIR`, `TMUX_SOCKET`, sources `swarm-terminal-adapter.sh`, runs `load_terminal_backend <name>`, then calls one adapter function. **stdout of `terminal_open_session` is captured as the window-id; stderr is swallowed.** Human-facing messages must be written to `/dev/tty`.
7. `sessions.tsv` columns (tab-separated): `index<TAB>role<TAB>session<TAB>display-name<TAB>agent`. Session names look like `swarmforge-<role>`.
8. A new adapter file requires ZERO upstream code changes: `SWARMFORGE_TERMINAL=warp ./swarm` loads `swarmforge/scripts/terminal-adapters/warp.sh` directly (unknown backend names pass through normalization; `load_terminal_backend` sources `$backend.sh`).
9. `watch` does not exist on stock macOS — don't use it in tests or docs.

## Upstream adapter interface (reference)
Every adapter implements 6 zsh functions. The `none.sh` upstream adapter shows the minimal shape:
- `terminal_backend_label` — echo human name
- `terminal_backend_can_open_sessions` — return 0 if the backend can open surfaces
- `terminal_backend_tracks_windows` — return 0 if window IDs can be tracked/queried
- `terminal_window_exists <id>` — return 0 if window still exists
- `terminal_open_session <session> <title> [sibling-id]` — open surface attached to tmux session; echo a window-id to stdout
- `terminal_close_window <id>` — close the surface
A full upstream `main` checkout is available read-only at `/tmp/swarmforge-probe` on this machine for reference (see `swarmforge/scripts/swarm-terminal-adapter.sh`, `terminal-adapters/*.sh`, `scripts/swarmforge.bb`).

## Deliverable 1: repo layout
- `adapter/warp.sh` — the Warp terminal adapter (core artifact)
- `install.sh` — installer run inside a target project directory
- `bin/swarm-warp` — launcher: `SWARMFORGE_TERMINAL=warp exec ./swarm "$@"`
- `test/smoke.sh` — UI-free smoke test
- `README.md` — prerequisites (Warp, zsh, git, tmux, babashka, ≥1 agent CLI), install one-liner, usage, limitations (one-click open; no watchdog), uninstall

## Deliverable 2: adapter/warp.sh behavior
- `terminal_backend_label` → `Warp`
- `terminal_backend_can_open_sessions` → 0 (true)
- `terminal_backend_tracks_windows` → 1 (false)
- `terminal_window_exists` → 1; `terminal_close_window` → 0 (no-ops)
- `terminal_open_session <session> <title> [sibling]`:
  - Acts only when `<session>` equals the FIRST session listed in `$WORKING_DIR/.swarmforge/sessions.tsv`; other calls no-op and echo a synthetic id (e.g. `warp-noop-<session>`)
  - Reads all roles from `sessions.tsv`; generates/overwrites `~/.warp/tab_configs/swarmforge_<sanitized-project>.toml` where `<sanitized-project>` = basename of `WORKING_DIR`, lowercased, non-alphanumerics → `_`
  - TOML: `name = "SwarmForge <project>"`, `color = "cyan"`; balanced grid via flat `[[panes]]` entries with split nodes (`children` arrays; equal sizing): N=1 → single leaf; N≤3 → one horizontal row; N=4 → 2×2; N=5–6 → 3 columns × ≤2 rows; first pane `is_focused = true`
  - Each leaf pane: `id` = role name, `type = "terminal"`, `directory = "<WORKING_DIR>"`, `commands = ["exec tmux -S <TMUX_SOCKET> attach-session -t <session>"]`
  - Note: Tab Config TOML `commands` entries are plain strings (NOT `exec:`-prefixed YAML mappings — that is the legacy launch-config format)
  - Prints instructions to `/dev/tty`: config written; open via sidebar `+` → `SwarmForge <project>`; panes self-close when the swarm stops
  - Echoes synthetic id (e.g. `warp-tab-config`) to stdout
- Edge cases: missing/empty `sessions.tsv` → message to `/dev/tty`, return 1; unwritable `~/.warp/tab_configs` → create dir or fail loudly; TOML string escaping for paths with spaces/quotes.

## Deliverable 3: install.sh
- Args: `--branch two-pack|four-pack|six-pack` (default `four-pack`), `--upstream-ref <ref>` (default `main`; applied to the archive URL), `--skip-fetch` (adapter-only install into an existing SwarmForge project)
- Steps: prerequisite check (zsh, git, tmux, bb — warn with `brew install` hints) → if no `./swarm`, fetch `https://github.com/unclebob/swarm-forge/archive/refs/heads/<branch>.tar.gz` and extract with `--strip-components=1` → install `adapter/warp.sh` to `swarmforge/scripts/terminal-adapters/warp.sh` (chmod +x) → install `bin/swarm-warp` to project root → print next steps
- Must work both from a local clone AND when piped (`curl -fsSL https://raw.githubusercontent.com/Cpicon/swarmforge-warp/main/install.sh | sh -s -- --branch two-pack`): when piped, fetch `adapter/warp.sh` and `bin/swarm-warp` from raw.githubusercontent.com (pin same ref)
- Idempotent; re-run to upgrade.

## Deliverable 4: test/smoke.sh (must pass before push)
- No Warp UI, no real `~/.warp`: run adapter under `HOME=$(mktemp -d)`
- Fabricate `.swarmforge/sessions.tsv` fixtures for 2 and 6 roles; set `SCRIPT_DIR`/`WORKING_DIR`/`TMUX_SOCKET`; source the adapter and call functions directly
- Assert: TOML generated at expected path; parses cleanly (`python3 -c 'import tomllib...'`); pane count/ids/commands correct; `is_focused` on first pane; second `terminal_open_session` call is a no-op (echoes synthetic id, does not rewrite file — compare mtime or checksum); non-first-session call no-ops; `tracks_windows` returns false
- Also validate `install.sh --skip-fetch` into a fake project dir installs files with correct permissions.

## Deliverable 5: docs + push
- README.md per Deliverable 1; include the verified limitations and a "How it works" diagram/section
- Conventional commits in logical chunks; push to `origin main` when smoke tests pass
- Every commit message ends with BOTH lines:
  - `Co-Authored-By: Oz <oz-agent@warp.dev>`
  - Claude Code's own co-author attribution line

## Explicitly OUT of scope for this session
- Live Warp UI E2E (requires a human click) — the orchestrator and user run it afterwards
- Upstream PR to unclebob/swarm-forge (separate follow-up)
- Any modification of files outside this repo clone, `$TMPDIR`, and temp HOMEs (in particular: do NOT write to the real `~/.warp/`)
