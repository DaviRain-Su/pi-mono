# Zig Pi Port — standing implementer prompt

Follow this on every slice. Prefer honesty over green checkboxes.

## Source of truth

- **Behavior**: TypeScript under `packages/{ai,agent,coding-agent,tui}/`.
- **Implementation**: Zig under `zig/src/{ai,agent,coding_agent,tui,cli}/`.
- Do not invent TS behavior. Read the TS file named by the picker before coding.

## Slice scope

1. Implement **only** `gaps[0]` from the picker (primary deliverable).
2. One implementer session ≈ 15–25 tool turns. Prefer a small API cluster.
3. Leave ledger **partial** when stretch gaps remain.

## Provider stream contract (Zig)

- `stream()` must not throw except `error.OutOfMemory`.
- Setup failures surface as `error_event` on the stream (see `zig/src/ai/providers/anthropic.zig`).
- Every provider needs the canonical setup-failure regression test pattern.

## Tests

- Prefer offline unit tests; no live network, no paid provider keys in suite tests.
- Tests must call **shipped public APIs**, not copy the algorithm into the test.
- Comment style: `// Pi: packages/.../file.ts "case name"` or `// Pi: packages/.../test/....ts`.
- After code changes in a slice: run the narrowest green command first, then leave a broader suite green when feasible:
  - `cd zig && zig build test-ai` / `test-agent` / `test-coding-agent` / `test-tui`
  - Prefer `cd zig && zig build test` before claiming the slice done if runtime allows.

## Forbidden

- `npm run build`, `npm test` (workspace fan-out) unless the user asked.
- `git reset --hard`, `git stash`, `git clean -fd`, `git add -A`.
- Stage only files you touched; never commit unless the user asks.
- Hardcoded key checks — use keybindings tables.
- Hand-edit `packages/ai/src/models.generated.ts`.

## Ledger honesty

| Status | Meaning |
|--------|---------|
| `missing` | No meaningful Zig surface |
| `partial` | Some behavior or structure; gaps listed |
| `implemented` | Behavior + offline shipped-API tests |
| `deferred` | Explicitly out of product scope (goal Exclusion list) |

Never promote to `implemented` without tests. Demote inflated rows when found.

## Files to update every slice

1. Zig sources + tests under `zig/`
2. Matching ledger row(s) in `docs/*_PARITY.md`
3. Brief note under Recent in `docs/PORT_STATUS.md`

## Commands cheat sheet

```bash
cd zig
zig build                      # needs rg + fd on PATH
zig build test                 # full unit suite
zig build test-ai
zig build test-agent
zig build test-coding-agent
zig build test-tui
zig build test-ts-rpc-parity   # when RPC wire is in scope
```
