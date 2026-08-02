# AI package parity (`packages/ai` → `zig/src/ai`)

Statuses: `missing` | `partial` | `implemented` | `deferred`

| TS source / cluster | Zig target | Status | Notes |
|---------------------|------------|--------|-------|
| `src/types.ts` core Model/Api/stream events | `ai/types.zig` | partial | Re-audit after KnownProvider / kimi-code-openai |
| `src/api/*` stream providers (openai, anthropic, google, …) | `ai/providers/*` | partial | TS moved providers under `api/`; Zig still owns streams — keep setup-failure contract |
| `src/providers/*.models.ts` + `models.generated.ts` aggregator | `ai/models.generated.zig` / registry | partial | Upstream shard catalog; regen path may differ |
| `src/env-api-keys.ts` | `ai/env_api_keys.zig` | partial | Keep kimi-code-openai + new providers |
| `src/auth/*` + oauth | `ai/oauth*` | partial | Upstream auth package split |
| `src/model-catalog.ts` / `models-store.ts` | TBD | missing | New upstream catalog helpers (audit top AI gap) |
| `src/api/constrained-sampling.ts` | TBD | missing | No Zig counterpart |
| `src/api/pi-messages.ts` | TBD | missing | No Zig stream provider |
| `src/api/openai-prompt-cache.ts` | TBD | missing | No dedicated Zig module |
| `src/auth/oauth/{device-code,openrouter,radius,kimi-coding}` | `ai/oauth*` | missing | Zig oauth index lacks these |
| `src/images*` | `ai/images*.zig` | partial | |
| Image / OpenRouter images | `ai/images*` | partial | |
| Faux provider | `ai/providers/faux*` | partial | Suite tests depend on faux behavior |

## Inventory gaps (seed)

- [ ] Diff `packages/ai/src/api/` file list vs `zig/src/ai/providers/`
- [ ] `kimi-code-openai` generator path vs Zig model table after shard migrate
- [ ] Provider setup-failure tests for every built-in stream
