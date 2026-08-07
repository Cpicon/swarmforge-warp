# Agent brief — swarmforge-warp build session

You are executing a pre-approved implementation plan: read `docs/IMPLEMENTATION_PLAN.md` in this repo FIRST — it contains hard-won, empirically verified constraints. Treat its "Verified constraints" section as ground truth; do not re-test Warp UI behavior (you cannot: no display interaction).

## Method
- Use your superpowers skills for the workflow (planning → TDD-style implementation → review). Write `test/smoke.sh` early and run it often.
- Work only inside this repo clone and temp dirs. Never write to the real `~/.warp/`.
- Reference material: upstream SwarmForge `main` checkout at `/tmp/swarmforge-probe` (read-only). Study `swarmforge/scripts/swarm-terminal-adapter.sh`, `swarmforge/scripts/terminal-adapters/none.sh` + `ghostty.sh`, and `open-terminal-surfaces!` in `swarmforge/scripts/swarmforge.bb` before writing the adapter.
- Shell: adapters are zsh (`#!/usr/bin/env zsh`), no `set -e` in sourced adapter files (they are sourced by a wrapper that must not die). `install.sh` should be POSIX-ish sh or zsh with strict mode — your call, justify in a comment.
- Validate zsh syntax (`zsh -n`) and run `test/smoke.sh` until green.

## Definition of done
1. All deliverables from the plan exist and smoke tests pass locally
2. README complete
3. Conventional commits pushed to `origin main` (remote is already configured, gh auth is active with WRITE)
4. Print a final summary: files created, test results, anything you deviated on and why

## Escalation
If you hit something genuinely ambiguous or blocked (e.g. push rejected), STOP and write the question/state clearly in your final message instead of guessing.
