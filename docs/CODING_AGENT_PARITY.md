# Coding-agent parity (`packages/coding-agent` → `zig/src/coding_agent`)

Statuses: `missing` | `partial` | `implemented` | `deferred`

| TS source / cluster | Zig target | Status | Notes |
|---------------------|------------|--------|-------|
| CLI parse / run modes | `coding_agent/cli/*`, `cli/*` | partial | |
| Experimental CLI option parser / transport | TBD | missing | Post-merge experimental endpoints |
| Remote session client coordination | TBD | missing / deferred | Depends on server/protocol scope |
| `core/model-runtime.ts` (+ models-store, provider-composer, remote-catalog) | TBD | missing | Full facade missing (audit) |
| `core/model-registry.ts` facade | registry/helpers | partial | Display names via runtime provider name |
| `core/extensions/types.ts` `agent_settled` | extensions event bus | missing | Zig bus has `sub_agent_readiness` only |
| `core/agent-session.ts` (+ runtime/services) | sessions / interactive | partial | Cluster not fully ledgered; re-audit |
| `core/project-trust.ts` + trust-manager | TBD | missing | Not on prior ledger |
| `cli/experimental/*` | TBD | missing | Post-merge experimental CLI |
| `client/remote-session.ts` | n/a | deferred | Needs server/protocol charter |
| `core/extensions` subagent readiness | `extensions/subagent*` | partial | Fork feature |
| Session manager / JSONL / HTML export | `sessions/*` | partial | |
| Interactive mode / keybindings | `interactive_mode/*` | partial | Configurable keybindings only |
| RPC / TS-RPC modes | `modes/*` | partial | Parity harnesses exist |
| Tools (read/bash/edit/write/grep/find) | `tools/*` | partial | |
| Package manager / config selector | `packages/*` | partial | |
| Auth storage / login | `auth/*` | partial | |

## Suggested first slices

1. Emit/observe `agent_settled` with offline test
2. Model display name resolution matching `ModelRuntime.getProvider()?.name`
3. Experimental CLI parse surface (transport address validation only)
