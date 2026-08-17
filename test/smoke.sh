#!/usr/bin/env zsh
#
# UI-free smoke test for swarmforge-warp.
#
# Runs the adapter exactly the way SwarmForge runs it (a fresh `zsh -c` with
# SCRIPT_DIR / WORKING_DIR / TMUX_SOCKET set as plain shell variables, stdout
# captured as the window id) but against a throwaway $HOME, so the real
# ~/.warp/ is never touched. No Warp UI and no tmux server are required.
#
# Requires: zsh, python3 >= 3.11 (tomllib), shasum.

emulate -L zsh
setopt pipe_fail

REPO_ROOT="${0:A:h:h}"
ADAPTER="$REPO_ROOT/adapter/warp.sh"
INSTALLER="$REPO_ROOT/install.sh"
LAUNCHER="$REPO_ROOT/bin/swarm-warp"

typeset -i PASSED=0 FAILED=0
typeset -a FAILURES

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/swarmforge-warp-smoke.XXXXXX")"
LAST_ERR="$SANDBOX/last-stderr.txt"
: >"$LAST_ERR"

cleanup() { [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- assertions

pass() { (( PASSED++ )); print -r -- "  ok   $1" }

fail() {
  (( FAILED++ ))
  FAILURES+=("$1")
  print -r -- "  FAIL $1"
  [[ -n "${2:-}" ]] && print -r -- "         $2"
}

assert_eq() {  # expected actual description
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}

assert_ne() {  # unexpected actual description
  if [[ "$1" != "$2" ]]; then pass "$3"; else fail "$3" "did not expect [$1]"; fi
}

assert_contains() {  # haystack needle description
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "[$2] not found in: $1"; fi
}

assert_status() {  # expected-status description command...
  local expected="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1
  assert_eq "$expected" "$?" "$desc"
}

assert_file() {
  if [[ -f "$1" ]]; then pass "$2"; else fail "$2" "missing file: $1"; fi
}

assert_executable() {
  if [[ -x "$1" ]]; then pass "$2"; else fail "$2" "not executable: $1"; fi
}

section() { print -r -- ""; print -r -- "== $1" }

# ------------------------------------------------------------------ fixtures

# Builds a fake SwarmForge project directory containing only the state file the
# adapter reads. Columns match upstream write-sessions-file!:
#   index<TAB>role<TAB>session<TAB>display-name<TAB>agent
make_project() {  # dir-name role...
  local dir="$SANDBOX/projects/$1"; shift
  mkdir -p "$dir/.swarmforge"
  local -i i=1
  local role
  : >"$dir/.swarmforge/sessions.tsv"
  for role in "$@"; do
    printf '%d\t%s\t%s\t%s\t%s\n' "$i" "$role" "swarmforge-$role" "$role" "codex" \
      >>"$dir/.swarmforge/sessions.tsv"
    (( i++ ))
  done
  print -r -- "$dir"
}

new_home() { local h="$SANDBOX/homes/$1"; mkdir -p "$h"; print -r -- "$h" }

# Invokes one adapter function in a subprocess shaped like SwarmForge's
# babashka caller. stdout is returned, stderr is captured to $LAST_ERR.
#
# `loader` mirrors how upstream reaches the adapter:
#   direct   -- source the file at top level (simple, used by most tests)
#   function -- source it from inside a function, exactly like upstream's
#               load_terminal_backend does. That scoping matters in zsh: any
#               typeset/readonly at the adapter's top level would be local to
#               the loader function and gone before the adapter is called.
run_adapter_via() {  # loader home workdir socket function [args...]
  local loader="$1" home="$2" workdir="$3" socket="$4"; shift 4
  local fn="$1"; shift
  local load="source ${(q)ADAPTER} || exit 97"
  if [[ "$loader" == function ]]; then
    load="load_terminal_backend() { source ${(q)ADAPTER} || return 97 }
load_terminal_backend || exit 97"
  fi
  local script="SCRIPT_DIR=${(q)REPO_ROOT}
WORKING_DIR=${(q)workdir}
TMUX_SOCKET=${(q)socket}
$load
$fn"
  local arg
  for arg in "$@"; do script+=" ${(q)arg}"; done
  HOME="$home" zsh -c "$script" 2>"$LAST_ERR"
}

run_adapter() {  # home workdir socket function [args...]
  run_adapter_via direct "$@"
}

config_path() {  # home slug
  print -r -- "$1/.warp/tab_configs/swarmforge_$2.toml"
}

# Normalised, greppable rendering of a Tab Config. Doubles as a strict
# "does this parse as TOML at all" check.
toml_summary() {
  python3 -c '
import sys, tomllib

with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)

print("name=%s" % doc.get("name"))
print("color=%s" % doc.get("color"))
panes = doc.get("panes", [])
print("panecount=%d" % len(panes))
for pane in panes:
    if "children" in pane:
        print("split id=%s split=%s children=%s"
              % (pane.get("id"), pane.get("split"), ",".join(pane["children"])))
    else:
        print("leaf id=%s type=%s directory=%s focused=%s commands=%s"
              % (pane.get("id"), pane.get("type"), pane.get("directory"),
                 pane.get("is_focused"), "|".join(pane.get("commands", []))))
' "$1"
}

# Every id referenced by a split node must exist, exactly once, and every node
# other than the root must be referenced exactly once. Catches dangling grids.
toml_tree_is_sound() {
  python3 -c '
import sys, tomllib

with open(sys.argv[1], "rb") as fh:
    panes = tomllib.load(fh).get("panes", [])

ids = [p["id"] for p in panes]
if len(ids) != len(set(ids)):
    sys.exit("duplicate pane ids: %s" % ids)

referenced = [c for p in panes if "children" in p for c in p["children"]]
if len(referenced) != len(set(referenced)):
    sys.exit("a pane is referenced by more than one split: %s" % referenced)

unknown = set(referenced) - set(ids)
if unknown:
    sys.exit("children reference unknown ids: %s" % sorted(unknown))

roots = set(ids) - set(referenced)
if roots != {panes[0]["id"]}:
    sys.exit("expected exactly one root (%s), found %s" % (panes[0]["id"], sorted(roots)))

focused = [p["id"] for p in panes if p.get("is_focused")]
if focused != [panes[1]["id"] if len(panes) > 1 else panes[0]["id"]] and len(focused) != 1:
    sys.exit("expected exactly one focused pane, found %s" % focused)
' "$1"
}

checksum() { shasum -a 256 "$1" | awk '{print $1}' }
mtime()    { stat -f %m "$1" }

# ------------------------------------------------------------- prerequisites

section "prerequisites"
assert_status 0 "python3 provides tomllib" python3 -c 'import tomllib'
assert_file "$ADAPTER" "adapter/warp.sh exists"
assert_file "$INSTALLER" "install.sh exists"
assert_file "$LAUNCHER" "bin/swarm-warp exists"

section "syntax"
assert_status 0 "adapter/warp.sh parses under zsh -n" zsh -n "$ADAPTER"
assert_status 0 "install.sh parses under sh -n" sh -n "$INSTALLER"
assert_status 0 "bin/swarm-warp parses under sh -n" sh -n "$LAUNCHER"
assert_status 0 "test/smoke.sh parses under zsh -n" zsh -n "$0"

# The adapter is sourced into a live shell; `set -e` there would kill the
# caller on the first failing conditional.
if grep -qE '^[[:space:]]*set -[a-z]*e' "$ADAPTER"; then
  fail "adapter does not enable errexit (it is sourced, not executed)"
else
  pass "adapter does not enable errexit (it is sourced, not executed)"
fi

# --------------------------------------------------- adapter interface shape

section "adapter interface"
PROJ2="$(make_project two coder cleaner)"
HOME2="$(new_home two)"
SOCK="/tmp/swarmforge-smoke/abc.sock"

assert_eq "Warp" "$(run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_backend_label)" \
  "terminal_backend_label is Warp"
assert_status 0 "terminal_backend_can_open_sessions is true" \
  run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_backend_can_open_sessions
assert_status 1 "terminal_backend_tracks_windows is false" \
  run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_backend_tracks_windows
assert_status 1 "terminal_window_exists is false for any id" \
  run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_window_exists warp-tab-config
assert_status 0 "terminal_close_window succeeds as a no-op" \
  run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_close_window warp-tab-config

# ------------------------------------------------------------ two-role layout

section "two roles: generation"
CFG2="$(config_path "$HOME2" two)"
OUT="$(run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_open_session swarmforge-coder "SwarmForge Coder" "")"
assert_eq "0" "$?" "first terminal_open_session succeeds"
assert_eq "warp-tab-config" "$OUT" "first call echoes the synthetic window id"
assert_file "$CFG2" "tab config written to \$HOME/.warp/tab_configs"
assert_eq "1" "$(find "$HOME2" -name '*.toml' | wc -l | tr -d ' ')" \
  "exactly one file created under the sandboxed HOME"

SUM2="$(toml_summary "$CFG2")"
assert_status 0 "two-role config is a sound pane tree" toml_tree_is_sound "$CFG2"
assert_contains "$SUM2" "name=SwarmForge two" "tab name is 'SwarmForge <project>'"
assert_contains "$SUM2" "color=cyan" "tab colour is cyan"
assert_contains "$SUM2" "panecount=3" "two roles produce root + 2 leaves"
assert_contains "$SUM2" "split id=root split=horizontal children=coder,cleaner" \
  "root is a horizontal split over both roles in sessions.tsv order"
assert_contains "$SUM2" "leaf id=coder type=terminal directory=$PROJ2 focused=True commands=exec tmux -S $SOCK attach-session -t swarmforge-coder" \
  "first leaf carries directory, exec command and focus"
assert_contains "$SUM2" "leaf id=cleaner type=terminal directory=$PROJ2 focused=None commands=exec tmux -S $SOCK attach-session -t swarmforge-cleaner" \
  "second leaf is not focused"

section "two roles: idempotence and no-ops"
SUM_BEFORE="$(checksum "$CFG2")"
MTIME_BEFORE="$(mtime "$CFG2")"

OUT="$(run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_open_session swarmforge-cleaner "SwarmForge Cleaner" warp-tab-config)"
assert_eq "warp-noop-swarmforge-cleaner" "$OUT" "non-first session echoes a synthetic no-op id"
assert_eq "$SUM_BEFORE" "$(checksum "$CFG2")" "non-first session leaves the config unchanged"
assert_eq "$MTIME_BEFORE" "$(mtime "$CFG2")" "non-first session does not touch the config mtime"

OUT="$(run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_open_session swarmforge-ghost "SwarmForge Ghost" "")"
assert_eq "warp-noop-swarmforge-ghost" "$OUT" "unknown session echoes a synthetic no-op id"
assert_eq "$MTIME_BEFORE" "$(mtime "$CFG2")" "unknown session does not touch the config mtime"

run_adapter "$HOME2" "$PROJ2" "$SOCK" terminal_open_session swarmforge-coder "SwarmForge Coder" "" >/dev/null
assert_eq "$SUM_BEFORE" "$(checksum "$CFG2")" "re-running the first session reproduces identical content"
assert_eq "$MTIME_BEFORE" "$(mtime "$CFG2")" "unchanged content is not rewritten (mtime preserved)"

# ------------------------------------------------------------- six-role grid

section "loading via load_terminal_backend (sourced inside a function)"
# Regression guard: the adapter must hold no top-level typeset/readonly state.
# zsh scopes those to the function that sources the file, so they would be gone
# by the time SwarmForge calls terminal_open_session.
PROJ_FN="$(make_project scoped coder cleaner)"
HOME_FN="$(new_home scoped)"
assert_eq "Warp" "$(run_adapter_via function "$HOME_FN" "$PROJ_FN" "$SOCK" terminal_backend_label)" \
  "label survives being sourced inside a function"
assert_eq "warp-tab-config" \
  "$(run_adapter_via function "$HOME_FN" "$PROJ_FN" "$SOCK" terminal_open_session swarmforge-coder "x" "")" \
  "window id survives being sourced inside a function"
assert_file "$(config_path "$HOME_FN" scoped)" "config is written when loaded inside a function"
assert_eq "warp-noop-swarmforge-cleaner" \
  "$(run_adapter_via function "$HOME_FN" "$PROJ_FN" "$SOCK" terminal_open_session swarmforge-cleaner "x" "")" \
  "no-op id survives being sourced inside a function"

# Column 0 == outside every function body, which is the scope that gets lost.
TOP_LEVEL_STATE='^(typeset|readonly|declare|export|local)[[:space:]]|^[A-Za-z_][A-Za-z0-9_]*=|^:[[:space:]]+\$\{'
if grep -qE "$TOP_LEVEL_STATE" "$ADAPTER"; then
  fail "adapter declares no variables at top level" \
       "$(grep -nE "$TOP_LEVEL_STATE" "$ADAPTER")"
else
  pass "adapter declares no variables at top level"
fi

section "six roles: 3x2 grid"
PROJ6="$(make_project sixpack specifier coder cleaner architect hardender QA)"
HOME6="$(new_home six)"
run_adapter "$HOME6" "$PROJ6" "$SOCK" terminal_open_session swarmforge-specifier "SwarmForge Specifier" "" >/dev/null
CFG6="$(config_path "$HOME6" sixpack)"
assert_file "$CFG6" "six-role tab config written"
SUM6="$(toml_summary "$CFG6")"
assert_status 0 "six-role config is a sound pane tree" toml_tree_is_sound "$CFG6"
assert_contains "$SUM6" "panecount=10" "six roles produce root + 3 columns + 6 leaves"
assert_contains "$SUM6" "split id=root split=horizontal children=col_1,col_2,col_3" \
  "root splits into three columns"
assert_contains "$SUM6" "split id=col_1 split=vertical children=specifier,coder" "column 1 stacks two roles"
assert_contains "$SUM6" "split id=col_2 split=vertical children=cleaner,architect" "column 2 stacks two roles"
assert_contains "$SUM6" "split id=col_3 split=vertical children=hardender,QA" "column 3 stacks two roles"
assert_contains "$SUM6" "leaf id=QA type=terminal" "role names are used verbatim as pane ids"
assert_eq "1" "$(print -r -- "$SUM6" | grep -c 'focused=True')" "exactly one pane is focused"

# ---------------------------------------------------------- remaining shapes

section "layout shapes for 1..5 roles"
typeset -A EXPECTED_COUNT EXPECTED_ROOT
EXPECTED_COUNT=(1 1  3 4  4 7  5 8)
EXPECTED_ROOT=(
  3 "split id=root split=horizontal children=r1,r2,r3"
  4 "split id=root split=horizontal children=col_1,col_2"
  5 "split id=root split=horizontal children=col_1,col_2,r5"
)
for n in 1 3 4 5; do
  typeset -a roles; roles=()
  for i in {1..$n}; do roles+=("r$i"); done
  proj="$(make_project "shape$n" "${roles[@]}")"
  home="$(new_home "shape$n")"
  run_adapter "$home" "$proj" "$SOCK" terminal_open_session "swarmforge-r1" "SwarmForge R1" "" >/dev/null
  cfg="$(config_path "$home" "shape$n")"
  sum="$(toml_summary "$cfg")"
  assert_status 0 "$n roles: sound pane tree" toml_tree_is_sound "$cfg"
  assert_contains "$sum" "panecount=${EXPECTED_COUNT[$n]}" "$n roles: expected node count"
  if [[ -n "${EXPECTED_ROOT[$n]}" ]]; then
    assert_contains "$sum" "${EXPECTED_ROOT[$n]}" "$n roles: expected root layout"
  else
    assert_contains "$sum" "leaf id=r1 type=terminal" "1 role: the single leaf is the root"
  fi
  assert_eq "1" "$(print -r -- "$sum" | grep -c 'focused=True')" "$n roles: exactly one focused pane"
done

# ----------------------------------------------------------------- edge cases

section "edge cases"
PROJ_MISSING="$SANDBOX/projects/no-state"
mkdir -p "$PROJ_MISSING"
HOME_EDGE="$(new_home edge)"
assert_status 1 "missing sessions.tsv fails loudly" \
  run_adapter "$HOME_EDGE" "$PROJ_MISSING" "$SOCK" terminal_open_session swarmforge-coder "x" ""
assert_contains "$(cat "$LAST_ERR")" "sessions.tsv" "missing sessions.tsv is explained to the user"

PROJ_EMPTY="$SANDBOX/projects/empty-state"
mkdir -p "$PROJ_EMPTY/.swarmforge"
: >"$PROJ_EMPTY/.swarmforge/sessions.tsv"
assert_status 1 "empty sessions.tsv fails loudly" \
  run_adapter "$HOME_EDGE" "$PROJ_EMPTY" "$SOCK" terminal_open_session swarmforge-coder "x" ""

assert_status 1 "an empty session argument fails loudly" \
  run_adapter "$HOME_EDGE" "$PROJ2" "$SOCK" terminal_open_session "" "x" ""

# sessions.tsv is written by babashka's `spit` and always ends in a newline,
# but a truncated write must not silently drop the last agent.
PROJ_NONL="$SANDBOX/projects/no-trailing-newline"
mkdir -p "$PROJ_NONL/.swarmforge"
printf '1\tcoder\tswarmforge-coder\tCoder\tcodex\n2\tcleaner\tswarmforge-cleaner\tCleaner\tcodex' \
  >"$PROJ_NONL/.swarmforge/sessions.tsv"
HOME_NONL="$(new_home nonl)"
run_adapter "$HOME_NONL" "$PROJ_NONL" "$SOCK" terminal_open_session swarmforge-coder "x" "" >/dev/null
assert_contains "$(toml_summary "$(config_path "$HOME_NONL" no_trailing_newline)")" \
  "children=coder,cleaner" "a last line without a trailing newline is still read"

ODD_PROJ="$(make_project 'My "Odd" Project (v2)' coder cleaner)"
ODD_HOME="$(new_home odd)"
ODD_SOCK="/tmp/swarm sockets/my \"sock\".sock"
run_adapter "$ODD_HOME" "$ODD_PROJ" "$ODD_SOCK" terminal_open_session swarmforge-coder "x" "" >/dev/null
ODD_CFG="$(config_path "$ODD_HOME" 'my__odd__project__v2_')"
assert_file "$ODD_CFG" "project name is lowercased and slugified for the filename"
ODD_SUM="$(toml_summary "$ODD_CFG")"
assert_contains "$ODD_SUM" "directory=$ODD_PROJ" "quotes and spaces in the path survive TOML escaping"
assert_contains "$ODD_SUM" "name=SwarmForge My \"Odd\" Project (v2)" "tab name keeps the original project name"
assert_contains "$ODD_SUM" "commands=exec tmux -S '/tmp/swarm sockets/my \"sock\".sock' attach-session -t swarmforge-coder" \
  "socket path with spaces and quotes is shell-quoted inside the command"

# -------------------------------------------------------------- the installer

section "install.sh --skip-fetch"
FAKE_PROJECT="$SANDBOX/fake-project"
mkdir -p "$FAKE_PROJECT/swarmforge/scripts/terminal-adapters"
printf '#!/usr/bin/env bash\ntrue\n' >"$FAKE_PROJECT/swarm"
printf '#!/usr/bin/env zsh\ntrue\n' >"$FAKE_PROJECT/swarmforge/scripts/swarmforge.sh"
chmod +x "$FAKE_PROJECT/swarm" "$FAKE_PROJECT/swarmforge/scripts/swarmforge.sh"

assert_status 0 "install.sh --help exits cleanly" sh "$INSTALLER" --help
assert_status 0 "install.sh --skip-fetch runs in a project directory" \
  sh -c "cd ${(q)FAKE_PROJECT} && sh ${(q)INSTALLER} --skip-fetch"

INSTALLED_ADAPTER="$FAKE_PROJECT/swarmforge/scripts/terminal-adapters/warp.sh"
assert_file "$INSTALLED_ADAPTER" "adapter installed into swarmforge/scripts/terminal-adapters"
assert_executable "$INSTALLED_ADAPTER" "installed adapter is executable"
assert_eq "$(checksum "$ADAPTER")" "$(checksum "$INSTALLED_ADAPTER")" "installed adapter matches the repo copy"
assert_file "$FAKE_PROJECT/swarm-warp" "launcher installed at the project root"
assert_executable "$FAKE_PROJECT/swarm-warp" "installed launcher is executable"
assert_eq "$(checksum "$LAUNCHER")" "$(checksum "$FAKE_PROJECT/swarm-warp")" "installed launcher matches the repo copy"

assert_status 0 "install.sh is idempotent" \
  sh -c "cd ${(q)FAKE_PROJECT} && sh ${(q)INSTALLER} --skip-fetch"
assert_eq "$(checksum "$ADAPTER")" "$(checksum "$INSTALLED_ADAPTER")" "re-install leaves the adapter intact"

assert_status 1 "install.sh rejects an unknown pack branch" \
  sh -c "cd ${(q)FAKE_PROJECT} && sh ${(q)INSTALLER} --branch nope --skip-fetch"
assert_status 1 "install.sh rejects an unknown flag" \
  sh -c "cd ${(q)FAKE_PROJECT} && sh ${(q)INSTALLER} --wat"

# install.sh must never fetch the pack when --skip-fetch is given, even in a
# directory with no ./swarm at all.
BARE_PROJECT="$SANDBOX/bare-project"
mkdir -p "$BARE_PROJECT"
assert_status 0 "install.sh --skip-fetch works without ./swarm" \
  sh -c "cd ${(q)BARE_PROJECT} && sh ${(q)INSTALLER} --skip-fetch"
assert_file "$BARE_PROJECT/swarmforge/scripts/terminal-adapters/warp.sh" \
  "adapter directory is created when absent"
if [[ ! -f "$BARE_PROJECT/swarm" ]]; then
  pass "--skip-fetch did not download the upstream pack"
else
  fail "--skip-fetch did not download the upstream pack" "./swarm appeared unexpectedly"
fi

# ------------------------------------------- the installer: the fetching path
#
# `--skip-fetch` never reaches fetch_pack, so everything the pack copy does to a
# project was previously untested. Rather than hit the network, put a stub
# `curl` at the front of PATH: install.sh only ever calls `curl -fsSL <url> -o
# <dest>`, so serving two locally built archives exercises the real fetch_pack
# and bootstrap_scripts, cp -R included.

section "install.sh pack fetch (stubbed curl, no network)"

FETCH_ROOT="$SANDBOX/fetch"
mkdir -p "$FETCH_ROOT/src/pack-root/swarmforge/roles" \
         "$FETCH_ROOT/src/scripts-root/swarmforge/scripts" \
         "$FETCH_ROOT/src/scripts-root/swarmforge/constitution/articles" \
         "$FETCH_ROOT/bin"

# A pack archive shaped like the real ones -- note it ships its own .gitignore.
print -r -- '#!/usr/bin/env bash' >"$FETCH_ROOT/src/pack-root/swarm"
chmod +x "$FETCH_ROOT/src/pack-root/swarm"
print -rl -- '.DS_Store' '.env' '.claude/' '.swarmforge/' '.worktrees/' 'swarmforge/scripts/' \
  >"$FETCH_ROOT/src/pack-root/.gitignore"
print -r -- 'window coder codex coder' >"$FETCH_ROOT/src/pack-root/swarmforge/swarmforge.conf"
print -r -- 'be a coder' >"$FETCH_ROOT/src/pack-root/swarmforge/roles/coder.prompt"

print -r -- 'true' >"$FETCH_ROOT/src/scripts-root/swarmforge/scripts/swarmforge.sh"
print -r -- 'an article' >"$FETCH_ROOT/src/scripts-root/swarmforge/constitution/articles/project.prompt"

# GitHub archives wrap everything in one top-level dir; install.sh strips it.
tar -czf "$FETCH_ROOT/pack.tar.gz"    -C "$FETCH_ROOT/src" pack-root
tar -czf "$FETCH_ROOT/scripts.tar.gz" -C "$FETCH_ROOT/src" scripts-root

cat >"$FETCH_ROOT/bin/curl" <<'STUB'
#!/bin/sh
# Stub curl for the smoke suite: understands only `-fsSL <url> -o <dest>`.
url=""; dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift ;;
    -*) : ;;
    *)  url="$1" ;;
  esac
  shift
done
case "$url" in
  *two-pack*|*four-pack*|*six-pack*) src="$STUB_PACK" ;;
  *)                                 src="$STUB_SCRIPTS" ;;
esac
cp "$src" "$dest"
STUB
chmod +x "$FETCH_ROOT/bin/curl"

run_install_with_stub() {  # project-dir [extra-args...]
  local dir="$1"; shift
  local args=""
  local a
  for a in "$@"; do args+=" ${(q)a}"; done
  STUB_PACK="$FETCH_ROOT/pack.tar.gz" \
  STUB_SCRIPTS="$FETCH_ROOT/scripts.tar.gz" \
  PATH="$FETCH_ROOT/bin:$PATH" \
    sh -c "cd ${(q)dir} && sh ${(q)INSTALLER} --branch six-pack$args" >/dev/null 2>&1
}

# The stub has to actually work, or every assertion below is vacuous.
FRESH_PROJECT="$SANDBOX/fetch-fresh"
mkdir -p "$FRESH_PROJECT"
assert_status 0 "stubbed fetch installs into a fresh project" \
  run_install_with_stub "$FRESH_PROJECT"
assert_file "$FRESH_PROJECT/swarm" "pack's ./swarm is installed"
assert_file "$FRESH_PROJECT/swarmforge/swarmforge.conf" "pack's swarmforge.conf is installed"
assert_file "$FRESH_PROJECT/swarmforge/scripts/swarmforge.sh" "scripts archive is bootstrapped"
assert_file "$FRESH_PROJECT/swarm-warp" "launcher is installed on the fetching path too"

# A project with no .gitignore should simply receive the pack's.
assert_contains "$(cat "$FRESH_PROJECT/.gitignore")" ".swarmforge/" \
  "a project without a .gitignore receives the pack's"

# ...but a project that already has one must keep it. This is the regression:
# `cp -R "$TMP_DIR/pack/." "$PROJECT_DIR/"` used to overwrite it wholesale,
# silently un-ignoring everything the project depended on.
KEEP_PROJECT="$SANDBOX/fetch-existing-gitignore"
mkdir -p "$KEEP_PROJECT"
print -rl -- '# project ignores' 'node_modules/' '*.tfvars' '.terraform/' '.env' \
  >"$KEEP_PROJECT/.gitignore"

run_install_with_stub "$KEEP_PROJECT"
KEEP_GI="$(cat "$KEEP_PROJECT/.gitignore")"

assert_contains "$KEEP_GI" "node_modules/"  "existing .gitignore keeps its own entries"
assert_contains "$KEEP_GI" "*.tfvars"       "existing .gitignore keeps every one of its entries"
assert_contains "$KEEP_GI" ".terraform/"    "existing .gitignore keeps entries the pack lacks"
assert_contains "$KEEP_GI" "# project ignores" "existing .gitignore keeps its comments"
assert_contains "$KEEP_GI" ".swarmforge/"   "the pack's entries are merged in"
assert_contains "$KEEP_GI" "swarmforge/scripts/" "the pack's remaining entries are merged in"
assert_eq "1" "$(print -r -- "$KEEP_GI" | grep -cxF '.env')" \
  "an entry present in both files is not duplicated"

# Re-running must not append the same block again.
run_install_with_stub "$KEEP_PROJECT"
assert_eq "1" "$(cat "$KEEP_PROJECT/.gitignore" | grep -cxF '.swarmforge/')" \
  "re-installing does not duplicate the merged entries"
assert_eq "1" "$(cat "$KEEP_PROJECT/.gitignore" | grep -cxF 'node_modules/')" \
  "re-installing does not duplicate the project's entries"

section "bin/swarm-warp"
assert_contains "$(cat "$LAUNCHER")" "SWARMFORGE_TERMINAL=warp" "launcher pins SWARMFORGE_TERMINAL=warp"
assert_contains "$(cat "$LAUNCHER")" './swarm' "launcher delegates to ./swarm"

# ---------------------------------------------------------------------- report

print -r -- ""
print -r -- "-------------------------------------------"
print -r -- "passed: $PASSED   failed: $FAILED"
if (( FAILED > 0 )); then
  print -r -- ""
  print -r -- "failures:"
  for f in "${FAILURES[@]}"; do print -r -- "  - $f"; done
  exit 1
fi
print -r -- "all smoke tests passed"
exit 0
