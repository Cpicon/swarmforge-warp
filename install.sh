#!/usr/bin/env sh
#
# swarmforge-warp installer -- run inside the project directory you want the
# swarm to work on.
#
#   Local clone:  ./install.sh --branch four-pack
#   Piped:        curl -fsSL https://raw.githubusercontent.com/Cpicon/swarmforge-warp/main/install.sh | sh -s -- --branch two-pack
#
# Written in POSIX sh (not zsh) precisely because of that second form: the
# piped invocation is executed by whatever /bin/sh the user has, so the script
# must not depend on zsh features. `set -eu` gives us strict mode; `pipefail`
# is not POSIX, so every pipeline that matters is written as separate steps.
set -eu

REPO_SLUG="Cpicon/swarmforge-warp"
UPSTREAM_SLUG="unclebob/swarm-forge"

PACK_BRANCH="four-pack"          # which swarm-forge pack to install
UPSTREAM_REF="main"              # swarm-forge ref holding swarmforge/scripts
OVERLAY_REF="${SWARMFORGE_WARP_REF:-main}"   # this repo's ref, for piped installs
SKIP_FETCH=0

TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT INT TERM

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
swarmforge-warp installer

Usage: install.sh [options]

Options:
  --branch <pack>       SwarmForge pack to install when the project has no
                        ./swarm yet: two-pack | four-pack | six-pack
                        (default: four-pack)
  --upstream-ref <ref>  Ref of unclebob/swarm-forge used for the archive that
                        provides swarmforge/scripts (default: main)
  --overlay-ref <ref>   Ref of Cpicon/swarmforge-warp to pull adapter/warp.sh
                        and bin/swarm-warp from when this script is piped
                        rather than run from a clone (default: main, or
                        $SWARMFORGE_WARP_REF)
  --skip-fetch          Do not download anything from SwarmForge; only install
                        the Warp adapter and launcher into an existing project
  -h, --help            Show this help

Re-running the installer is safe: it overwrites the two files it owns and
leaves everything else alone.
USAGE
}

# ------------------------------------------------------------------ arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --branch)        [ $# -ge 2 ] || die "--branch needs a value";        PACK_BRANCH="$2"; shift ;;
    --branch=*)      PACK_BRANCH="${1#--branch=}" ;;
    --upstream-ref)  [ $# -ge 2 ] || die "--upstream-ref needs a value";  UPSTREAM_REF="$2"; shift ;;
    --upstream-ref=*) UPSTREAM_REF="${1#--upstream-ref=}" ;;
    --overlay-ref)   [ $# -ge 2 ] || die "--overlay-ref needs a value";   OVERLAY_REF="$2"; shift ;;
    --overlay-ref=*) OVERLAY_REF="${1#--overlay-ref=}" ;;
    --skip-fetch)    SKIP_FETCH=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)               printf 'error: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$PACK_BRANCH" in
  two-pack|four-pack|six-pack) ;;
  *) die "unknown pack '$PACK_BRANCH' (expected two-pack, four-pack or six-pack)" ;;
esac

[ -n "$UPSTREAM_REF" ] || die "--upstream-ref must not be empty"
[ -n "$OVERLAY_REF" ]  || die "--overlay-ref must not be empty"

PROJECT_DIR="$(pwd)"

# -------------------------------------------------------------- prerequisites

missing=""
check_tool() {  # command hint
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "$1 not found -- $2"
    missing="$missing $1"
  fi
}

check_tool zsh   "SwarmForge's adapters are zsh scripts (macOS ships zsh; otherwise: brew install zsh)"
check_tool git   "SwarmForge creates a git worktree per agent (brew install git)"
check_tool tmux  "every agent runs inside a tmux session (brew install tmux)"
check_tool bb    "SwarmForge itself is a babashka script (brew install borkdude/brew/babashka)"
check_tool curl  "needed to download SwarmForge (brew install curl)"

if [ -n "$missing" ]; then
  warn "install the missing tools above before running the swarm:$missing"
fi

if ! command -v codex >/dev/null 2>&1 \
  && ! command -v claude >/dev/null 2>&1 \
  && ! command -v gemini >/dev/null 2>&1; then
  warn "no agent CLI found (codex / claude / gemini) -- SwarmForge needs the one named in swarmforge/swarmforge.conf"
fi

need_curl() {
  command -v curl >/dev/null 2>&1 || die "curl is required to download $1"
}

# ---------------------------------------------------------- upstream fetching

# Append to $2 every non-comment entry of $1 that $2 does not already contain.
#
# The result is staged beside the destination and moved into place in one step,
# matching provide() below, so an interrupted merge cannot leave a half-written
# .gitignore. The staging file must be a sibling of the destination: $TMP_DIR is
# usually on another filesystem, where `mv` degrades to a non-atomic copy.
#
# Variables carry an _mg_ prefix because POSIX sh has no `local` and everything
# here is global.
merge_gitignore() {  # pack-gitignore project-gitignore
  _mg_pack="$1"
  _mg_project="$2"
  _mg_tmp="$_mg_project.swarmforge-warp.tmp"

  cat "$_mg_project" >"$_mg_tmp" || die "could not stage $_mg_project"

  _mg_added=0
  while IFS= read -r _mg_line || [ -n "$_mg_line" ]; do
    [ -n "$_mg_line" ] || continue
    case "$_mg_line" in '#'*) continue ;; esac

    # `--` stops an entry beginning with `-` being read as a grep option: `-e`
    # would swallow the file operand, leaving grep to read this loop's stdin
    # (the pack) and silently drop every remaining entry. Matching against the
    # staging file also collapses duplicates within the pack itself.
    #
    # `|| _mg_rc=$?` keeps a no-match exempt from errexit while still telling
    # exit 1 (absent) apart from exit 2 (could not read the file), which `if
    # grep` would have merged into a single "not found" branch.
    _mg_rc=0
    grep -qxF -- "$_mg_line" "$_mg_tmp" </dev/null || _mg_rc=$?
    case "$_mg_rc" in
      0) continue ;;
      1) : ;;
      *) die "could not read $_mg_project while merging ignore rules (grep exit $_mg_rc)" ;;
    esac

    if [ "$_mg_added" -eq 0 ]; then
      # The leading newline is load-bearing: it terminates the project's last
      # line when that file ends without one, instead of fusing the header onto
      # it. test/smoke.sh pins this.
      printf '\n# SwarmForge (added by swarmforge-warp)\n' >>"$_mg_tmp"
      _mg_added=1
    fi
    printf '%s\n' "$_mg_line" >>"$_mg_tmp"
  done <"$_mg_pack"

  if [ "$_mg_added" -eq 0 ]; then
    rm -f "$_mg_tmp"
    return 0
  fi
  mv -f "$_mg_tmp" "$_mg_project" || die "could not update $_mg_project"
  say "  merged the pack's ignore rules into your .gitignore"
}

fetch_pack() {
  url="https://github.com/${UPSTREAM_SLUG}/archive/refs/heads/${PACK_BRANCH}.tar.gz"
  say "Downloading SwarmForge ${PACK_BRANCH} ..."
  need_curl "the ${PACK_BRANCH} pack"
  TMP_DIR="${TMP_DIR:-$(mktemp -d)}"
  mkdir -p "$TMP_DIR/pack"
  curl -fsSL "$url" -o "$TMP_DIR/pack.tar.gz" || die "could not download $url"
  tar -xzf "$TMP_DIR/pack.tar.gz" -C "$TMP_DIR/pack" --strip-components=1 \
    || die "could not unpack $url"

  # The pack ships its own .gitignore, and `cp -R` would replace the project's
  # wholesale -- silently un-ignoring everything it covered. Take the pack's
  # copy out of the tree *before* the copy, so the project's file is never a
  # candidate for being overwritten in the first place.
  #
  # Backing the project's file up and restoring it afterwards is not equivalent:
  # `cp -R` can clobber it and then fail on a later file (a read-only path,
  # ENOSPC, Ctrl-C -- likely, given this script is documented as `curl | sh`),
  # and errexit would then skip the restore while the EXIT trap deletes the only
  # remaining copy. Never touching it has no such window.
  if [ -f "$TMP_DIR/pack/.gitignore" ]; then
    mv "$TMP_DIR/pack/.gitignore" "$TMP_DIR/gitignore.pack" \
      || die "could not set the ${PACK_BRANCH} pack's .gitignore aside"
  fi

  cp -R "$TMP_DIR/pack/." "$PROJECT_DIR/" \
    || die "could not copy the ${PACK_BRANCH} pack into $PROJECT_DIR (your .gitignore was not modified)"
  say "  installed ./swarm and swarmforge/ from ${PACK_BRANCH}"

  if [ ! -f "$TMP_DIR/gitignore.pack" ]; then
    warn "the ${PACK_BRANCH} pack shipped no .gitignore; add .swarmforge/, .worktrees/"
    warn "and swarmforge/scripts/ to yours by hand, or the swarm's working state"
    warn "will show up as untracked files in your repository"
  elif [ -f "$PROJECT_DIR/.gitignore" ]; then
    merge_gitignore "$TMP_DIR/gitignore.pack" "$PROJECT_DIR/.gitignore"
  else
    cp "$TMP_DIR/gitignore.pack" "$PROJECT_DIR/.gitignore" \
      || die "could not install the ${PACK_BRANCH} pack's .gitignore"
  fi
}

# The pack branches deliberately ship without swarmforge/scripts; ./swarm
# bootstraps it from the main archive on first run -- but only when the
# directory is absent. Since we are about to create
# swarmforge/scripts/terminal-adapters/, we must do that bootstrap ourselves
# first, or ./swarm would skip it and then fail to find swarmforge.sh.
bootstrap_scripts() {
  if [ -d swarmforge/scripts ] && [ -d swarmforge/scripts/shared-articles ]; then
    return 0
  fi
  url="https://github.com/${UPSTREAM_SLUG}/archive/refs/heads/${UPSTREAM_REF}.tar.gz"
  say "Downloading SwarmForge scripts (${UPSTREAM_REF}) ..."
  need_curl "swarmforge/scripts"
  TMP_DIR="${TMP_DIR:-$(mktemp -d)}"
  mkdir -p "$TMP_DIR/scripts"
  curl -fsSL "$url" -o "$TMP_DIR/scripts.tar.gz" || die "could not download $url"
  tar -xzf "$TMP_DIR/scripts.tar.gz" -C "$TMP_DIR/scripts" --strip-components=1 \
    || die "could not unpack $url"

  mkdir -p swarmforge
  if [ ! -d swarmforge/scripts ]; then
    cp -R "$TMP_DIR/scripts/swarmforge/scripts" swarmforge/scripts
    say "  installed swarmforge/scripts"
  fi
  if [ -d "$TMP_DIR/scripts/swarmforge/constitution/articles" ]; then
    mkdir -p swarmforge/scripts/shared-articles
    cp -R "$TMP_DIR/scripts/swarmforge/constitution/articles/." swarmforge/scripts/shared-articles/
  fi
}

if [ "$SKIP_FETCH" -eq 0 ]; then
  [ -x ./swarm ] || [ -f ./swarm ] || fetch_pack
  bootstrap_scripts
elif [ ! -f swarmforge/scripts/swarmforge.sh ]; then
  warn "--skip-fetch was given but swarmforge/scripts/swarmforge.sh is missing."
  warn "./swarm only self-installs swarmforge/scripts when that directory does not"
  warn "exist yet -- and this installer is about to create it. Re-run without"
  warn "--skip-fetch, or restore swarmforge/scripts manually, or ./swarm will fail."
fi

# --------------------------------------------------------------- our own files

# Running from a clone? Then copy; otherwise pull the two files from GitHub.
SELF_DIR=""
if [ -n "${0:-}" ] && [ -f "$0" ]; then
  SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
fi

RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/${OVERLAY_REF}"

provide() {  # repo-relative-path destination
  dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$1" ]; then
    cp "$SELF_DIR/$1" "$dest.swarmforge-warp.tmp"
  else
    need_curl "$1"
    curl -fsSL "$RAW_BASE/$1" -o "$dest.swarmforge-warp.tmp" \
      || die "could not download $RAW_BASE/$1"
  fi
  mv -f "$dest.swarmforge-warp.tmp" "$dest"
  chmod +x "$dest"
}

provide adapter/warp.sh  "$PROJECT_DIR/swarmforge/scripts/terminal-adapters/warp.sh"
provide bin/swarm-warp   "$PROJECT_DIR/swarm-warp"

say ""
say "swarmforge-warp installed in $PROJECT_DIR"
say "  swarmforge/scripts/terminal-adapters/warp.sh   the Warp adapter"
say "  swarm-warp                                     launcher (SWARMFORGE_TERMINAL=warp ./swarm)"
say ""
say "Next:"
say "  1. ./swarm-warp"
say "  2. When it prints the tab config path, open Warp's sidebar '+' menu and"
say "     pick \"SwarmForge $(basename "$PROJECT_DIR")\" -- every agent appears as a"
say "     pane in that single tab."
say ""
