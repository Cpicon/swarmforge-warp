#!/usr/bin/env zsh
#
# SwarmForge terminal adapter for the Warp terminal (macOS).
#
# Instead of opening one OS window per agent, this adapter writes a single Warp
# Tab Config describing every agent session as a pane in one tab. The user then
# opens that tab once from Warp's sidebar `+` menu.
#
# Installed by swarmforge-warp as:
#   swarmforge/scripts/terminal-adapters/warp.sh
# Activated with:
#   SWARMFORGE_TERMINAL=warp ./swarm
#
# This file is *sourced* by swarm-terminal-adapter.sh into a live shell, so it
# deliberately does not enable `set -e`: a failing conditional here must not
# kill the caller. Every helper is prefixed `_warp_` and every variable is
# `local` to avoid leaking into the sourcing shell.
#
# Contract provided by the caller (see swarmforge.bb `adapter-script`):
#   SCRIPT_DIR   swarmforge/scripts
#   WORKING_DIR  the project root
#   TMUX_SOCKET  the tmux socket path
# stdout of terminal_open_session is captured as the window id; stderr is
# swallowed. Anything a human needs to read goes to /dev/tty.

# This file defines functions and nothing else, on purpose. upstream's
# load_terminal_backend sources it from *inside a function*, and in zsh any
# `typeset`/`readonly`/`local` executed there is scoped to that function and
# disappears when it returns. Function definitions survive; variables do not.
# So every value the adapter needs is resolved at call time instead.

# ----------------------------------------------------------------- utilities

# Human-facing output. stderr is discarded by the caller, so prefer the
# controlling terminal and fall back to stderr when there is none (CI, tests).
_warp_notify() {
  if [[ -w /dev/tty ]]; then
    print -r -- "$@" >/dev/tty 2>/dev/null || print -r -- "$@" >&2
  else
    print -r -- "$@" >&2
  fi
}

# Escape a value for a TOML basic string (the quotes are added by the caller).
_warp_toml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  print -r -- "$s"
}

# basename of the project, lowercased, everything else collapsed to `_`.
_warp_project_slug() {
  local base="${1:a:t}"
  local slug="${${(L)base}//[^a-z0-9]/_}"
  print -r -- "${slug:-project}"
}

# Read the ordered role list out of SwarmForge's state file. SwarmForge writes
# this file for *all* roles before the first terminal_open_session call, so one
# read is enough to lay out the whole tab.
# Columns: index<TAB>role<TAB>session<TAB>display-name<TAB>agent
_warp_read_sessions() {
  local file="$1"
  local -a roles sessions
  local index role session rest

  # `|| [[ -n "$role" ]]` keeps a final line that has no trailing newline.
  while IFS=$'\t' read -r index role session rest || [[ -n "$role" ]]; do
    [[ -n "$role" && -n "$session" ]] || continue
    roles+=("$role")
    sessions+=("$session")
    role=""
  done <"$file"

  (( ${#roles} > 0 )) || return 1

  # Returned through globals because zsh functions cannot return arrays.
  _warp_roles=("${roles[@]}")
  _warp_sessions=("${sessions[@]}")
  return 0
}

# Number of columns for a balanced grid of n panes.
#   1..3 -> a single row      4 -> 2x2      5..6 -> 3 columns
#   >6   -> ceil(sqrt(n)) columns
_warp_column_count() {
  local -i n="$1"
  if (( n <= 3 )); then
    print -r -- "$n"
    return
  fi
  local -i cols=1
  while (( cols * cols < n )); do (( cols++ )); done
  print -r -- "$cols"
}

# Internal split nodes are named `root` and `col_<n>` to match Warp's own
# examples. Roles come from swarmforge.conf, so a role could in principle be
# called "root"; escalate the prefix until no leaf id can collide.
_warp_node_prefix() {
  local prefix="" role
  local -i clash
  while true; do
    clash=0
    for role in "$@"; do
      if [[ "$role" == "${prefix}root" || "$role" == "${prefix}col_"* ]]; then
        clash=1
        break
      fi
    done
    (( clash )) || break
    prefix="swarm_${prefix}"
  done
  print -r -- "$prefix"
}

# Emit the `[[panes]]` block for one leaf (an agent's tmux session).
_warp_emit_leaf() {
  local id="$1" directory="$2" command="$3" focused="$4"
  print -r -- ""
  print -r -- "[[panes]]"
  print -r -- "id = \"$(_warp_toml_escape "$id")\""
  print -r -- 'type = "terminal"'
  print -r -- "directory = \"$(_warp_toml_escape "$directory")\""
  print -r -- "commands = [\"$(_warp_toml_escape "$command")\"]"
  (( focused )) && print -r -- "is_focused = true"
  return 0
}

# Emit the `[[panes]]` block for a split node. `children` are pane ids; Warp
# sizes all children of a split equally, which is exactly what we want.
_warp_emit_split() {
  local id="$1" split="$2"; shift 2
  local child rendered=""
  for child in "$@"; do
    rendered+="${rendered:+, }\"$(_warp_toml_escape "$child")\""
  done
  print -r -- ""
  print -r -- "[[panes]]"
  print -r -- "id = \"$(_warp_toml_escape "$id")\""
  print -r -- "split = \"$split\""
  print -r -- "children = [$rendered]"
  return 0
}

# Render the whole Tab Config to stdout.
_warp_render_config() {
  local project="$1" working_dir="$2" socket="$3"; shift 3
  local -a roles sessions
  local -i half=$(( $# / 2 ))
  roles=("${@[1,$half]}")
  sessions=("${@[$half+1,$#]}")

  local -i total=${#roles}
  local -i cols=$(_warp_column_count "$total")
  local prefix=$(_warp_node_prefix "${roles[@]}")
  local root_id="${prefix}root"

  # Distribute leaves over columns, front-loading the remainder so earlier
  # columns are the fuller ones (6 -> 2,2,2 ; 5 -> 2,2,1 ; 4 -> 2,2).
  local -a col_size
  local -i base=$(( total / cols )) rem=$(( total % cols )) c
  for (( c = 1; c <= cols; c++ )); do
    col_size+=( $(( base + (c <= rem ? 1 : 0) )) )
  done

  # Work out each column's node id: a lone pane in a column *is* the leaf, so
  # no split node is emitted for it.
  local -a column_ids
  local -i cursor=1
  for (( c = 1; c <= cols; c++ )); do
    if (( col_size[c] == 1 )); then
      column_ids+=("${roles[cursor]}")
    else
      column_ids+=("${prefix}col_${c}")
    fi
    (( cursor += col_size[c] ))
  done

  print -r -- "# Generated by swarmforge-warp -- https://github.com/Cpicon/swarmforge-warp"
  print -r -- "# Rewritten every time the swarm starts. Local edits will be lost."
  print -r -- "name = \"$(_warp_toml_escape "SwarmForge ${project}")\""
  print -r -- 'color = "cyan"'

  # Warp resolves the pane tree from a flat list whose first entry is the root.
  if (( total > 1 )); then
    _warp_emit_split "$root_id" "horizontal" "${column_ids[@]}"
  fi

  cursor=1
  local -i r focused
  for (( c = 1; c <= cols; c++ )); do
    if (( col_size[c] > 1 )); then
      _warp_emit_split "${prefix}col_${c}" "vertical" "${roles[@]:$((cursor - 1)):${col_size[c]}}"
    fi
    for (( r = 0; r < col_size[c]; r++ )); do
      local idx=$(( cursor + r ))
      focused=$(( idx == 1 ))
      _warp_emit_leaf \
        "${roles[idx]}" \
        "$working_dir" \
        "exec tmux -S ${(q-)socket} attach-session -t ${(q-)sessions[idx]}" \
        "$focused"
    done
    (( cursor += col_size[c] ))
  done
  return 0
}

# ------------------------------------------------- SwarmForge adapter surface

terminal_backend_label() {
  echo "Warp"
}

terminal_backend_can_open_sessions() {
  return 0
}

# Warp exposes no API to enumerate or close panes, so window ids cannot be
# tracked. SwarmForge treats this as a supported degraded mode and skips the
# window watchdog (see open-terminal-surfaces! in swarmforge.bb).
terminal_backend_tracks_windows() {
  return 1
}

terminal_window_exists() {
  return 1
}

terminal_close_window() {
  # Panes run `exec tmux attach`, so they close themselves when the swarm stops.
  return 0
}

# Called once per role by SwarmForge. Only the first role does any work: it
# writes one Tab Config covering every pane. Later calls are no-ops that echo a
# synthetic id so SwarmForge's bookkeeping stays happy.
terminal_open_session() {
  local session="${1:-}"
  local sessions_file="${WORKING_DIR:-}/.swarmforge/sessions.tsv"

  if [[ -z "$session" ]]; then
    _warp_notify "swarmforge-warp: terminal_open_session called without a session name; aborting."
    return 1
  fi

  local -a _warp_roles _warp_sessions
  if [[ ! -r "$sessions_file" ]] || ! _warp_read_sessions "$sessions_file"; then
    _warp_notify "swarmforge-warp: cannot read any sessions from ${sessions_file}."
    _warp_notify "swarmforge-warp: the Warp adapter needs that file to lay out the tab; aborting."
    return 1
  fi

  if [[ "$session" != "${_warp_sessions[1]}" ]]; then
    # Every pane is already described by the config written on the first call.
    echo "warp-noop-${session}"
    return 0
  fi

  local project="${${WORKING_DIR:-}:a:t}"
  local slug=$(_warp_project_slug "$WORKING_DIR")
  # Where Warp looks for tab configs; overridable for tests and unusual setups.
  local config_dir="${SWARMFORGE_WARP_TAB_CONFIG_DIR:-${HOME}/.warp/tab_configs}"
  local config_file="${config_dir}/swarmforge_${slug}.toml"

  if ! mkdir -p "$config_dir" 2>/dev/null; then
    _warp_notify "swarmforge-warp: cannot create ${config_dir}; aborting."
    return 1
  fi

  local rendered
  rendered=$(_warp_render_config \
    "$project" "${WORKING_DIR:-}" "${TMUX_SOCKET:-}" \
    "${_warp_roles[@]}" "${_warp_sessions[@]}") || {
    _warp_notify "swarmforge-warp: failed to render the tab config; aborting."
    return 1
  }

  # Only touch the file when the content actually changes: Warp may be reading
  # it, and an unchanged mtime makes repeat calls provably side-effect free.
  if [[ ! -f "$config_file" ]] || [[ "$rendered" != "$(cat "$config_file")" ]]; then
    if ! print -r -- "$rendered" >"$config_file" 2>/dev/null; then
      _warp_notify "swarmforge-warp: cannot write ${config_file}; aborting."
      return 1
    fi
  fi

  _warp_notify ""
  _warp_notify "  SwarmForge → Warp"
  _warp_notify "  Wrote tab config: ${config_file}"
  _warp_notify "  Open it with:     Warp sidebar '+' menu → \"SwarmForge ${project}\""
  _warp_notify "  All ${#_warp_roles} agents appear as panes in that one tab."
  _warp_notify "  The panes close themselves when the swarm stops."
  _warp_notify ""

  # Synthetic window id: Warp has no pane query/close API, so this is an opaque
  # token that only ever travels back through SwarmForge's own bookkeeping.
  echo "warp-tab-config"
  return 0
}
