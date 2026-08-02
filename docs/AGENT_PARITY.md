# Agent package parity (`packages/agent` → `zig/src/agent`)

Statuses: `missing` | `partial` | `implemented` | `deferred`

| TS source / cluster | Zig target | Status | Notes |
|---------------------|------------|--------|-------|
| `src/agent-loop.ts` / `agent.ts` | `agent/agent_loop.zig`, `agent.zig` | partial | Core loop present; re-check settled/retry edges |
| `src/stream-fn.ts` | stream wiring | partial | New upstream module |
| `src/harness/agent-harness.ts` | `agent/harness/agent_harness.zig` | partial | Do not rewrite whole file in one slice |
| `src/harness/session/repository.ts` | `agent/harness/session/repo/*` | missing | Zig repo/* near-empty stubs; treat as missing vs full SessionRepository (audit 2026-08-02) |
| `src/harness/session/jsonl-repo.ts` | `session/repo/jsonl.zig` | missing | Stub only |
| `src/harness/session/memory-repo.ts` | `session/repo/memory.zig` | missing | Stub only |
| `src/harness/session/search.ts` | TBD | missing | Reject unsupported search paths; coding-agent has separate session_search |
| `src/harness/session/array-session-index.ts` | `session/array_session_index.zig` | implemented | Pure append/replace/readHead/readEntry/readEntries/findEntriesOnBranch/readPathToRootOrCompaction + label/name/stats projections; co-located minimal entry types; offline tests. Not yet wired into memory/jsonl repos. |
| `src/harness/session/keyed-operation-queue.ts` | `session/keyed_operation_queue.zig` | implemented | Pure queue + offline thread tests (was mis-marked missing) |
| Bounded branch queries (`branch-query`) | `session/array_session_index.zig` | partial | Array index readers implemented; storage/repo compose still missing |
| SQLite session backend | n/a | deferred | `packages/storage/sqlite-node`; Zig JSONL/memory first |
| `src/harness/compaction/*` | `agent/harness/compaction/*` | partial | |
| `src/harness/tools/*` (bash/edit/read/write) | coding-agent tools only today | missing | No `zig/src/agent/harness/tools`; tools live under coding_agent |
| Session readers storage-owned | TBD | missing | `session-readers` / rename fork module |

## Suggested first slices

1. ~~Keyed operation queue behavior (pure, testable)~~ done
2. Wire `ArraySessionIndex` into memory/jsonl session storage/repos
3. Unsupported session search rejection
