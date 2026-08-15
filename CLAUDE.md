# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Authoritative rules

`AGENTS.md` at the repo root is the source of truth for development rules (style, code quality, commands you must not run, git/PR workflow, changelog, release flow, provider-addition checklist, parallel-agent git rules, Zig-specific notes). Read it before any non-trivial change. The points below are pointers and architecture context, not a substitute.

## Repository shape

This is a dual-implementation monorepo for the **pi coding agent**:

- **TypeScript packages** (`packages/`) — the production codebase, npm workspaces under `@earendil-works/*`.
- **Zig native port** (`zig/`) — a from-scratch Zig 0.16.x implementation that ships as a single `pi` binary and is wire-compatible with the TS implementation through ts-rpc and provider-parity test harnesses.

The two implementations are kept in lockstep; changes to provider semantics, RPC protocol, or session/auth shapes generally need parity coverage on both sides.

### TypeScript packages (layered, lower → higher)

- `packages/ai` — Unified multi-provider LLM streaming API. Owns `Api` types, provider implementations under `src/providers/`, env-key detection, model registry. Provider model list lives in `src/models.generated.ts` (regenerate via `scripts/generate-models.ts`, never hand-edit).
- `packages/agent` — Provider-agnostic agent loop, tool calling, state.
- `packages/coding-agent` — The `pi` CLI: interactive TUI mode, print mode, RPC mode, session manager, extensions, tools (read/bash/edit/write/grep/find), keybindings, slash commands. Entry: `src/cli.ts`. Major subdirs: `src/cli/`, `src/core/`, `src/modes/{interactive,rpc}`.
- `packages/tui` — Terminal UI primitives with differential rendering.
- `packages/web-ui` — Web components for chat surfaces.
- `packages/mom`, `packages/pods` — supporting packages.

Build order is hard-coded in the root `npm run build` script: tui → ai → agent → coding-agent → web-ui. `npm run check` requires that prior `build` because `web-ui` consumes generated `.d.ts`.

### Zig implementation

Zig packages live under `zig/packages/` (`pi-types`, `pi-ai`, `pi-agent-core`, `pi-tui`, `pi-shared`, `pi-coding-agent`, `pi-cli`). `zig/src/main.zig` is the process entry. Root `zig/build.zig` assembles them with `b.dependency(...)`. Import names stay `ai` / `agent` / `tui` / `coding_agent` / `cli` / `shared` / `pi-types`. Provider implementations live in `zig/packages/pi-ai/src/providers/`. See `zig/docs/packaging.md` for the one-way dependency rules.

Notable Zig conventions (see AGENTS.md "Zig Implementation Notes" for details):
- All provider `stream()` functions follow a strict contract: never throw except `error.OutOfMemory`; setup failures must surface as an `error_event` on the stream. The reference is `zig/packages/pi-ai/src/providers/anthropic.zig`. There is a canonical setup-failure regression test template that every provider must have.
- Helper modules ported from `packages/ai/src/providers/` (e.g. `cloudflare`, `github-copilot-headers`) have explicit wire-up sites in `openai.zig` and `anthropic.zig` — those are the canonical integration points.
- Keybindings are centrally configurable; never hardcode key checks. New `Action` variants in `keybindings.zig` require call-site updates across `input_dispatch.zig`, overlays, `interactive_mode.zig`, and rendering.
- `zig build`, `zig build run`, and `zig build test` fail early if `rg` and `fd` are missing from PATH (used by the grep/find tools).

## Commands

### Forbidden (per AGENTS.md)

Do not run: `npm run dev`, `npm run build`, `npm test`. The build script is multi-step and slow; the user runs builds. `npm test` is the workspace fan-out — use the per-package or filtered forms below.

### Routine

```bash
# Type/format/lint check (full output, no tail). Required after code changes; not after doc-only changes.
# Note: requires a prior build to have produced d.ts files for web-ui.
npm run check

# Run full TS test suite without LLM credentials (strips API keys, skips paid providers).
./test.sh

# Run a single TS test from inside the relevant package
cd packages/<pkg>
npx tsx ../../node_modules/vitest/dist/cli.js --run test/path/to/file.test.ts

# Run pi from sources from any directory
./pi-test.sh                   # uses ambient API keys
./pi-test.sh --no-env          # strips API keys (mirrors test.sh)

# Zig
cd zig
zig build                      # build to zig-out/bin/pi (verifies rg+fd on PATH)
zig build test                 # full unit suite (includes ts-rpc parity, provider parity, MCP coverage)
zig build test-coding-agent    # coding-agent slice
zig build test-ai              # ai slice
zig build test-agent           # agent slice
zig build test-tui             # TUI slice
zig build test-tidy            # source guardrails
zig build test-ts-rpc-parity   # standalone TS↔Zig RPC byte-parity (needs libsimdjson installed; in-tree copy used by `test`)
zig build test-openai-chat-parity
zig build test-openai-responses-parity
zig build test-bedrock-parity
zig build test-cross-area      # tuistory-driven integration tests (requires `tuistory` on PATH)
```

### Coding-agent test conventions

- The TS coding-agent suite under `packages/coding-agent/test/suite/` uses `test/suite/harness.ts` plus the **faux provider**. Never use real provider APIs, real keys, or paid tokens in suite tests.
- Issue regressions: `packages/coding-agent/test/suite/regressions/<issue-number>-<short-slug>.test.ts`.
- If you create or modify a test file, run it and iterate until it passes.

### TUI testing with tmux

`AGENTS.md` documents the tmux recipe for driving pi's interactive TUI in a controlled 80×24 terminal — use it whenever validating interactive flows, selectors, or keybindings.

## Cross-cutting things to know

- **Lockstep versioning**: every release bumps all packages together. Use `npm run release:patch` / `release:minor`. There are no major releases.
- **CHANGELOGs**: per-package under `packages/*/CHANGELOG.md`. Entries always go under `## [Unreleased]`. Released sections are immutable. Do not edit `CHANGELOG.md` in contributor PRs (maintainers add entries).
- **Generated files**: `packages/ai/src/models.generated.ts` is regenerated; modify `packages/ai/scripts/generate-models.ts` instead. It is fine to include the generated file in a commit alongside actual changes.
- **Adding a provider** to `packages/ai` is a multi-file, cross-package operation (types, provider impl, lazy registration, env detection, model generation, broad test matrix, coding-agent display name + default model + env docs, README, CHANGELOG). The full checklist lives in AGENTS.md "Adding a New LLM Provider" — follow it in order.
- **Extension substrate**: the coding agent has a layered extension system (Zig native + WASM + `process_jsonl`) with policy/provenance enforcement, digest-bound policies, and `extensions.lock.json`. The Zig SDK + package authoring substrate is complete for WASM-first extensions and is Zig-only — it does not change TypeScript runtime behavior. See `README.md` "Extension substrate" and `zig/docs/wasm-extension-*.md` for the design history.
- **Parallel agents may share this worktree.** Stage only files you modified (`git add <paths>`, never `git add -A`/`.`). Never `git reset --hard`, `git stash`, `git clean -fd`, or `--no-verify`. Full rules in AGENTS.md "Git Rules for Parallel Agents".
- **No commits unless the user asks.** No PRs opened directly — work in feature branches and merge into main only on user approval.
