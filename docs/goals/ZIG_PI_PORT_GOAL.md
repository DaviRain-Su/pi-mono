# Goal: Zig Pi Port (post-upstream-main)

## Objective

Keep the Zig native `pi` binary wire- and behavior-compatible with the TypeScript implementation in this monorepo after each `upstream/main` sync. Port only what is in-scope for the Zig product; leave deferred packages deferred until explicitly promoted.

## Success criteria (goal complete only when all hold)

1. `docs/PORT_STATUS.md` and domain ledgers show no **missing** or inflated **implemented** rows for in-scope Wave A/B items listed under Priority after the latest merge base with `upstream/main`.
2. `cd zig && zig build test` is green (or a documented, temporary slice with `zig build test-<area>` green and residual failures listed as ledger rows, not hidden).
3. Every row marked **implemented** has offline Zig tests that call shipped Zig APIs (not reimplemented logic in the test), with a comment pointing at the TS source or test case.
4. TS under `packages/` is the behavioral source of truth for port work; Zig changes live under `zig/`. Do not "fix" TS to match an incomplete Zig port unless the user asked for a TS bugfix.

## Drivers

| Mechanism | Role |
|-----------|------|
| `/goal` | Long-running autonomous objective; host verifies completion claims |
| `/workflow zig-pi-port-slice` | One vertical slice: Pick → Implement → Verify → Report |
| `/workflow zig-pi-port-audit` | Read-only ledger honesty + inventory vs `packages/` |

Preferred loop:

```
/goal Port TypeScript pi behavior into Zig per docs/goals/ZIG_PI_PORT_GOAL.md. Each work unit: launch workflow zig-pi-port-slice (max_slices 1 or 2). Prefer domain auto. Never mark complete without zig build test green and honest ledgers. Standing rules: docs/goals/ZIG_PI_PORT_PROMPT.md.

# Between goal rounds or after a large merge:
/workflow zig-pi-port-audit {"domain":"auto"}
/workflow zig-pi-port-slice {"domain":"auto","max_slices":1}
```

## Priority order (hard)

1. **ai** — provider stream contract, model catalog/registry, auth/env keys, models.generated parity
2. **agent** — loop, tools, harness session (repository/storage), compaction, events
3. **coding-agent** — CLI, session manager, model runtime facade, extensions, interactive/RPC/TS-RPC
4. **tui** — components, layout, keybindings, render parity
5. **orchestrator/cli** — `main`/`cli` wiring only after lower layers settle

## Deferred (out of scope unless promoted)

- `packages/evals`
- `packages/protocol` / `packages/server` full product surface (note inventory only until a Zig server target is chartered)
- `packages/storage/sqlite-node` native SQLite backend (Zig may keep JSONL/memory until SQLite is chartered)
- `packages/web-ui`, `packages/mom`, `packages/pods`, `packages/client` (unless coding-agent depends on a concrete API)

## Post-merge focus (2026-08-02 `upstream/main` sync)

Highest-value gaps after merge `781ab4a12`:

- Agent harness session storage: repositories, branch queries, readers, keyed queues
- Coding-agent model runtime / registry facade vs TS `model-runtime.ts`
- Extension events: `agent_settled` + existing `sub_agent_readiness`
- AI provider layout (`packages/ai/src/api/*`) and catalog shards vs Zig providers
- Experimental remote/transport CLI options (coding-agent) when lower layers allow

## Anti-goals

- Parallel writers on the same ledger/test tree in one workflow run
- Marking **implemented** without offline tests on shipped APIs
- Porting entire harness/session stacks in one slice (one primary gap only)
- Editing `packages/ai/src/models.generated.ts` by hand (regenerate from script)

## References

- Standing implementer rules: `docs/goals/ZIG_PI_PORT_PROMPT.md`
- Dashboard: `docs/PORT_STATUS.md`
- Ledgers: `docs/AI_PARITY.md`, `docs/AGENT_PARITY.md`, `docs/CODING_AGENT_PARITY.md`, `docs/TUI_PARITY.md`
- Zig conventions: root `AGENTS.md` (Zig Implementation Notes)
- Historical review: `zig/docs/REVIEW.md` (may lag; ledgers win)
