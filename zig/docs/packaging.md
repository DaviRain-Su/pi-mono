# Zig package layout

Single-repo packages under `zig/packages/`. Split repo is a later publish
action, not an architecture action. TypeScript `packages/` is unchanged.

## Dependency direction

```text
main → pi-cli → pi-coding-agent → pi-agent-core → pi-types
                         ├──────→ pi-ai ─────────→ pi-types
                         └──────→ pi-tui → pi-shared
```

Rules:

1. Dependencies only point down.
2. `pi-agent-core` sees canonical types and injected ports. It does not import
   `ai`, HTTP clients, provider SDKs, or TUI.
3. `pi-types` has no IO and no product imports.
4. `pi-ai` does not import agent, TUI, or coding-agent.
5. `pi-tui` does not import coding-agent, agent, or ai.
6. New packages are created only when a second owner or a quarantine boundary
   exists. Do not split tools, workspace, or telemetry in this wave.

## Packages

| Package | Module import name | Owns | May depend on |
|---------|--------------------|------|----------------|
| `pi-types` | `pi-types` | Canonical message, tool, usage, stop, stream event, thin Model/Context/SimpleStreamOptions | none |
| `pi-shared` | `shared` | Host-neutral TUI helpers (theme, fuzzy, keybinding schema) | none |
| `pi-ai` | `ai` | Model plane, providers, catalog, wire | `pi-types` |
| `pi-agent-core` | `agent` | Loop, transcript, StreamFn port | `pi-types` only |
| `pi-tui` | `tui` | Terminal widgets and renderer | `shared`, vaxis |
| `pi-coding-agent` | `coding_agent` | Product harness, tools, session, extensions | core, ai, tui, shared, types |
| `pi-cli` | `cli` | Flags, resolve, mode dispatch | coding-agent and below |

`src/main.zig` is the process entry. It assembles packages and does not own
loop or provider protocol details.

## Import guardrails

`zig/test/import-boundaries.sh` (via `zig build test-import-boundaries` and
`test-tidy`) enforces the forbidden edges above.

## Deliberately not in this wave

- Scheme / `pi-live`
- Extracting tools or session from coding-agent
- Changing the TypeScript package graph
- Independent semver or a second repo
- Dynamic plugin ABI
