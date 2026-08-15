#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail=0

# Prefer the packaged layout; fall back to the pre-split src/ tree so the
# script stays usable during the move.
agent_src=""
ai_src=""
tui_src=""
types_src=""
coding_tools=""
coding_extensions=""

if [[ -d packages/pi-agent-core/src ]]; then
  agent_src=packages/pi-agent-core/src
elif [[ -d src/agent ]]; then
  agent_src=src/agent
fi

if [[ -d packages/pi-ai/src ]]; then
  ai_src=packages/pi-ai/src
elif [[ -d src/ai ]]; then
  ai_src=src/ai
fi

if [[ -d packages/pi-tui/src ]]; then
  tui_src=packages/pi-tui/src
elif [[ -d src/tui ]]; then
  tui_src=src/tui
fi

if [[ -d packages/pi-types/src ]]; then
  types_src=packages/pi-types/src
fi

if [[ -d packages/pi-coding-agent/src/tools ]]; then
  coding_tools=packages/pi-coding-agent/src/tools
  coding_extensions=packages/pi-coding-agent/src/extensions
elif [[ -d src/coding_agent/tools ]]; then
  coding_tools=src/coding_agent/tools
  coding_extensions=src/coding_agent/extensions
fi

check_no_match() {
  local scope="$1"
  local pattern="$2"
  local label="$3"

  if [[ ! -d "$scope" ]]; then
    return 0
  fi

  if rg -n --glob '*.zig' "$pattern" "$scope" >/tmp/pi-import-boundary.$$ 2>/dev/null; then
    echo "import-boundary violation: $label"
    cat /tmp/pi-import-boundary.$$
    fail=1
  fi
  rm -f /tmp/pi-import-boundary.$$
}

check_no_match "$tui_src" '@import\("coding_agent"\)|@import\(".*coding_agent|@import\("\.\./coding_agent|@import\("\.\./\.\./coding_agent' 'tui must not import coding_agent'
check_no_match "$tui_src" '@import\("agent"\)|@import\("pi-agent-core"\)' 'tui must not import agent'
check_no_match "$tui_src" '@import\("ai"\)|@import\("pi-ai"\)' 'tui must not import ai'

check_no_match "$agent_src" '@import\("ai"\)|@import\("pi-ai"\)' 'agent-core must not import ai'
check_no_match "$agent_src" '@import\("tui"\)|@import\("pi-tui"\)' 'agent-core must not import tui'
check_no_match "$agent_src" '@import\("coding_agent"\)|@import\("pi-coding-agent"\)' 'agent-core must not import coding_agent'

check_no_match "$ai_src" '@import\("agent"\)|@import\("pi-agent-core"\)' 'ai must not import agent'
check_no_match "$ai_src" '@import\("tui"\)|@import\("pi-tui"\)' 'ai must not import tui'
check_no_match "$ai_src" '@import\("coding_agent"\)|@import\("pi-coding-agent"\)' 'ai must not import coding_agent'

check_no_match "$types_src" '@import\("ai"\)|@import\("agent"\)|@import\("tui"\)|@import\("coding_agent"\)|@import\("cli"\)|@import\("shared"\)' 'pi-types must not import product packages'

check_no_match "$coding_tools" '@import\("\.\./interactive_mode|@import\("interactive_mode' 'tools must not import interactive_mode'
check_no_match "$coding_extensions" '@import\("\.\./tui|@import\("\.\./\.\./tui|@import\("tui"\)' 'extensions must not import tui'

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo 'import-boundaries: ok'
