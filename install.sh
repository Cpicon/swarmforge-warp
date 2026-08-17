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

CONFIGURE=0            # apply the post-install fixes described in usage()
AGENT=""               # empty means "detect one that is installed"
AGENT_ARGS=""
AGENT_ARGS_SET=0
FIRST_ROLE_WORKTREE=1  # move the first role out of the user's checkout
MERGE_ARTICLES=1
SCAFFOLD_PROMPT=0

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

  --configure           Apply the post-install fixes every project needs:
                          * point every role at an agent CLI that is installed
                          * move the first role out of your working checkout
                          * make upstream's shared constitution articles
                            reachable by the agents
                        Implied by --agent, --agent-args and
                        --scaffold-project-prompt.
  --agent <cli>         Agent for every role: claude | codex | copilot | grok,
                        or `claudio` as shorthand for claude with permission
                        checks bypassed. Default: the first of claude, codex,
                        copilot, grok found on PATH.
  --agent-args <args>   Extra arguments appended to every role's agent command,
                        e.g. '--permission-mode plan'. Overrides the arguments
                        implied by `--agent claudio`.
  --keep-first-role-in-root
                        Leave the first role in your working checkout. Not
                        recommended: switching branches there removes that
                        agent's constitution mid-run, and you cannot use the
                        checkout yourself while the swarm runs.
  --no-shared-articles  Do not merge upstream's shared constitution articles.
  --scaffold-project-prompt
                        Overwrite swarmforge/constitution/articles/project.prompt
                        with one describing THIS repository, with the decisions
                        a human must make left as TODOs. The packs ship a
                        project.prompt describing their own repository, which
                        every agent otherwise reads as fact.

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
    --configure)     CONFIGURE=1 ;;
    --agent)         [ $# -ge 2 ] || die "--agent needs a value";      AGENT="$2"; CONFIGURE=1; shift ;;
    --agent=*)       AGENT="${1#--agent=}"; CONFIGURE=1 ;;
    --agent-args)    [ $# -ge 2 ] || die "--agent-args needs a value"; AGENT_ARGS="$2"; AGENT_ARGS_SET=1; CONFIGURE=1; shift ;;
    --agent-args=*)  AGENT_ARGS="${1#--agent-args=}"; AGENT_ARGS_SET=1; CONFIGURE=1 ;;
    --keep-first-role-in-root) FIRST_ROLE_WORKTREE=0 ;;
    --no-shared-articles)      MERGE_ARTICLES=0 ;;
    --scaffold-project-prompt) SCAFFOLD_PROMPT=1; CONFIGURE=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)               printf 'error: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# `claudio` is not a SwarmForge agent -- swarmforge.bb validates that field
# against a fixed allowlist and rejects anything else at config-parse time. It
# is the common shell alias for `claude --dangerously-skip-permissions`, so
# translate it into something the parser accepts with the same posture.
if [ "$AGENT" = claudio ]; then
  AGENT=claude
  if [ "$AGENT_ARGS_SET" -eq 0 ]; then
    AGENT_ARGS="--permission-mode bypassPermissions"
    AGENT_ARGS_SET=1
  fi
fi

case "$AGENT" in
  ""|claude|codex|copilot|grok) ;;
  *) die "unknown agent '$AGENT' (expected claude, codex, copilot, grok or claudio)" ;;
esac

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

# --------------------------------------------------------------- --configure
#
# The packs are configured for the repository they were authored in. Left alone
# they name an agent CLI you may not have, park the first role in your own
# working checkout, and leave upstream's shared constitution articles somewhere
# nothing reads. These three fixes are identical in every project.

detect_agent() {
  for candidate in claude codex copilot grok; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Rewrite each `window` line, preserving comments, blank lines, field order and
# the optional receive mode. Format:
#   window <role> <agent> <worktree> [task|batch] [extra-cli-args...]
configure_conf() {
  _cc_conf="$PROJECT_DIR/swarmforge/swarmforge.conf"
  if [ ! -f "$_cc_conf" ]; then
    warn "no swarmforge/swarmforge.conf to configure"
    return 0
  fi
  _cc_tmp="$_cc_conf.swarmforge-warp.tmp"
  : >"$_cc_tmp"
  _cc_first=1
  # Field splitting is wanted here; globbing is not.
  set -f
  while IFS= read -r _cc_line || [ -n "$_cc_line" ]; do
    case "$_cc_line" in
      'window '*)
        # shellcheck disable=SC2086
        set -- $_cc_line
        _cc_role="$2"; _cc_agent="$3"; _cc_wt="$4"
        shift 4
        _cc_mode=""
        case "${1:-}" in task|batch) _cc_mode="$1"; shift ;; esac
        _cc_rest="$*"

        [ -n "$AGENT" ] && _cc_agent="$AGENT"
        [ "$AGENT_ARGS_SET" -eq 1 ] && _cc_rest="$AGENT_ARGS"

        # `master` and `none` are the two names SwarmForge maps to the main
        # working directory instead of .worktrees/<name>. Naming the worktree
        # after the role gives that agent its own checkout, so branch switches
        # in the project root cannot remove its constitution mid-run.
        if [ "$_cc_first" -eq 1 ] && [ "$FIRST_ROLE_WORKTREE" -eq 1 ] && [ "$_cc_wt" = master ]; then
          _cc_wt="$_cc_role"
        fi
        _cc_first=0

        printf 'window %s %s %s' "$_cc_role" "$_cc_agent" "$_cc_wt" >>"$_cc_tmp"
        [ -n "$_cc_mode" ] && printf ' %s' "$_cc_mode" >>"$_cc_tmp"
        [ -n "$_cc_rest" ] && printf ' %s' "$_cc_rest" >>"$_cc_tmp"
        printf '\n' >>"$_cc_tmp"
        ;;
      *) printf '%s\n' "$_cc_line" >>"$_cc_tmp" ;;
    esac
  done <"$_cc_conf"
  set +f
  mv -f "$_cc_tmp" "$_cc_conf" || die "could not update $_cc_conf"
  say "  configured swarmforge.conf for ${AGENT}"
}

# constitution.prompt points agents at swarmforge/constitution/articles/, but a
# pack install leaves upstream's shared articles in scripts/shared-articles/,
# which nothing references. Copy them across without touching a pack-local
# article of the same name -- upstream treats those as deliberate overrides.
merge_shared_articles() {
  _ma_src="$PROJECT_DIR/swarmforge/scripts/shared-articles"
  _ma_dst="$PROJECT_DIR/swarmforge/constitution/articles"
  [ -d "$_ma_src" ] || return 0
  mkdir -p "$_ma_dst" || die "could not create $_ma_dst"
  _ma_copied=0
  for _ma_file in "$_ma_src"/*.prompt; do
    [ -f "$_ma_file" ] || continue
    _ma_base="${_ma_file##*/}"
    [ -e "$_ma_dst/$_ma_base" ] && continue
    cp "$_ma_file" "$_ma_dst/$_ma_base" || die "could not install $_ma_base"
    _ma_copied=$((_ma_copied + 1))
  done
  [ "$_ma_copied" -eq 0 ] || say "  made $_ma_copied shared constitution article(s) reachable"
}

# The packs ship a project.prompt describing their own repository -- language
# included -- and every agent reads it as fact. Replace it with one describing
# this repository. Detected facts are stated; everything else is a TODO,
# because a confidently wrong constitution is worse than an obviously empty one.
scaffold_project_prompt() {
  _sp_dst="$PROJECT_DIR/swarmforge/constitution/articles/project.prompt"
  mkdir -p "$(dirname "$_sp_dst")" || die "could not create $(dirname "$_sp_dst")"

  _sp_langs=""
  _sp_note=""
  add_lang() { _sp_langs="${_sp_langs:+$_sp_langs, }$1"; }

  if [ -f "$PROJECT_DIR/pyproject.toml" ] || [ -f "$PROJECT_DIR/setup.py" ] \
     || [ -f "$PROJECT_DIR/requirements.txt" ] \
     || [ -n "$(find "$PROJECT_DIR" -name pyproject.toml -maxdepth 3 -print -quit 2>/dev/null)" ]; then
    add_lang "Python"
    [ -n "$(find "$PROJECT_DIR" -name 'uv.lock' -maxdepth 3 -print -quit 2>/dev/null)" ] \
      && _sp_note="${_sp_note}- Dependencies are managed with \`uv\`. Use \`uv sync\` and \`uv run\`.
"
  fi
  [ -f "$PROJECT_DIR/package.json" ] && add_lang "TypeScript/JavaScript"
  [ -f "$PROJECT_DIR/go.mod" ]       && add_lang "Go"
  [ -f "$PROJECT_DIR/Cargo.toml" ]   && add_lang "Rust"
  [ -n "$(find "$PROJECT_DIR" -name '*.tf' -maxdepth 3 -print -quit 2>/dev/null)" ] \
    && add_lang "Terraform"
  [ -n "$_sp_langs" ] || _sp_langs="TODO: state the project language"

  cat >"$_sp_dst" <<PROMPT
# Project Rules

## Project Shape
- This project runs SwarmForge with ${AGENT}-backed agents.
- Languages detected in this repository: ${_sp_langs}.
- TODO: confirm the above, and delete any language that is incidental here.
${_sp_note}- TODO: name the test command (for example \`uv run pytest\`, \`npm test\`, \`go test ./...\`) and the lint command. A change is not done until both pass.

## Repository Layout
- TODO: describe where source, tests and infrastructure live, and where new
  code belongs. Agents work in separate worktrees and cannot ask each other.

## Guardrails
- TODO: list anything agents must never run. Commands that mutate cloud
  infrastructure, cost money, touch production, or need credentials the agents
  do not have belong here.

## Local Configuration
- Preserve project-local SwarmForge configuration under \`swarmforge/\`.
- Keep swarm state local under \`.swarmforge/\`, worktrees under \`.worktrees/\`,
  and shared scripts under \`swarmforge/scripts/\`.

## Ownership
- Do not change another role's prompt or workflow ownership without explicit
  user direction.
PROMPT
  say "  scaffolded swarmforge/constitution/articles/project.prompt (edit the TODOs)"
}

if [ "$CONFIGURE" -eq 1 ]; then
  if [ -z "$AGENT" ]; then
    AGENT="$(detect_agent)" || die "no agent CLI found on PATH (looked for claude, codex, copilot, grok); pass --agent explicitly"
    say "  detected agent CLI: $AGENT"
  elif ! command -v "$AGENT" >/dev/null 2>&1; then
    warn "--agent $AGENT was requested but $AGENT is not on PATH; the swarm will fail to start until it is"
  fi
  configure_conf
  [ "$MERGE_ARTICLES" -eq 1 ] && merge_shared_articles
  [ "$SCAFFOLD_PROMPT" -eq 1 ] && scaffold_project_prompt
fi

say ""
say "swarmforge-warp installed in $PROJECT_DIR"
say "  swarmforge/scripts/terminal-adapters/warp.sh   the Warp adapter"
say "  swarm-warp                                     launcher (SWARMFORGE_TERMINAL=warp ./swarm)"
say ""
say "Next:"
say "  1. Fill in swarmforge/constitution/articles/project.prompt -- every agent"
say "     reads it as fact. The README has a prompt you can paste into a plain"
say "     Claude Code session to finish it."
say "  2. Commit swarmforge/ before launching. Each role gets a git worktree made"
say "     with 'git worktree add HEAD', which carries committed files only, so an"
say "     uncommitted config leaves every agent with no role and no constitution."
say "     Do not want this in a shared repo? Run the swarm from its own clone --"
say "     see \"Keeping it out of a shared repository\" in the README."
say "  3. ./swarm-warp"
say "  4. When it prints the tab config path, open Warp's sidebar '+' menu and"
say "     pick \"SwarmForge $(basename "$PROJECT_DIR")\" -- every agent appears as a"
say "     pane in that single tab."
say ""
