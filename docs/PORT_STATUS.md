# Zig ↔ TypeScript Port Status

**Last merge base with upstream:** `upstream/main` @ merge `781ab4a12` (2026-08-02)  
**Drivers:** `docs/goals/ZIG_PI_PORT_GOAL.md`, workflow `zig-pi-port-slice`, optional `/goal`  
**Ledgers:** `AI_PARITY.md` · `AGENT_PARITY.md` · `CODING_AGENT_PARITY.md` · `TUI_PARITY.md`

## Domain rollup

| Domain | Overall | Notes |
|--------|---------|--------|
| ai | partial | Large provider surface present; catalog/runtime/auth layout drifted with upstream `api/` + shard models |
| agent | partial | Loop/tools/session JSONL present; harness v2 storage (repos, branch queries, readers) lags merge |
| coding-agent | partial | Interactive/RPC/TS-RPC usable; model-runtime facade, agent_settled, remote/experimental CLI gaps |
| tui | partial | Core TUI present; upstream layout stack / alt-screen / image redraw work needs re-audit |
| protocol/server/evals | deferred | Inventory only until Zig product charter expands |

## Priority queue (after 781ab4a12)

From `zig-pi-port-audit` (2026-08-02), refreshed:

1. Agent: Jsonl session backend/repo compose + thin `InMemorySessionRepository` facade
2. Agent: Unsupported session search rejection + storage-owned readers
3. Coding-agent: `ModelRuntime` facade (display name / auth offline)
4. Coding-agent: `agent_settled` on extension bus (keep `sub_agent_readiness`)
5. AI: `model-catalog` + `models-store` parity
6. TUI: layout stack / scroll-view inventory then minimal port

## Recent notes

- 2026-08-02: Ported `InMemorySessionBackend` (`zig/src/agent/harness/session/repo/memory.zig`) composing `ArraySessionIndex` + `KeyedOperationQueue`, pure fork helpers in `repo/shared.zig`, SessionStorage projections, disposed rejection; offline tests mirroring TS InMemory cases via `appendEntry`.
- 2026-08-02: Ported pure `ArraySessionIndex` (`zig/src/agent/harness/session/array_session_index.zig`) with bounded branch-query + projections + offline tests; marked keyed-operation-queue implemented (was already green).
- 2026-08-02: Merged `earendil-works/pi` main into `zig-implementation`. Seeded goal + ledgers + workflows.
- 2026-08-02: `zig-pi-port-audit` complete — no demote_candidates (seed had no `implemented` rows). Soft honesty: agent `session/repo/*` stubs are closer to **missing** than partial vs TS `SessionRepository`. Full inventory in workflow scratch report.

## How to continue

```text
/workflow zig-pi-port-slice {"domain":"auto","max_slices":1}
/workflow zig-pi-port-audit {"domain":"agent"}

/goal Port TypeScript pi into Zig per docs/goals/ZIG_PI_PORT_GOAL.md. Each unit: zig-pi-port-slice max_slices 1. Rules: docs/goals/ZIG_PI_PORT_PROMPT.md. Prefer agent session storage then model-runtime then agent_settled.
```
