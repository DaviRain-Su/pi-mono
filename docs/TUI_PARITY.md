# TUI parity (`packages/tui` → `zig/src/tui`)

Statuses: `missing` | `partial` | `implemented` | `deferred`

| TS source / cluster | Zig target | Status | Notes |
|---------------------|------------|--------|-------|
| Core TUI / differential render | `tui/tui.zig` | partial | |
| Editor component | `tui/editor_component.zig` + components | partial | |
| Keybindings / keys | `tui/keybindings.zig`, `keys.zig` | partial | Never hardcode key checks in app code |
| Markdown / image | components + `terminal_image.zig` | partial | Upstream alt-screen image redraws |
| Layout stack (`stack`, `h-stack`, `v-stack`, `scroll-view`) | TBD | missing | No Zig modules (audit) |
| `layout.ts` + `layout-node.ts` | TBD | missing | |
| Settings list | components | partial | |
| Alt-screen / main-screen split | terminal flags only | partial | Partial via terminal flags, not full TS split |
| `word-navigation.ts` / `native-modifiers.ts` | TBD | missing | |

## Suggested first slices

1. Inventory layout API vs Zig component tree
2. Alt-screen image redraw behavior with visual/offline tests where present
