# `agent` module

This module turns the `ai` layer's single-response stream into an agent turn
loop: append user input, stream an assistant message, execute requested tools,
append tool results, and repeat until the assistant stops or the caller aborts.

The TypeScript reference is `packages/agent/src/agent-loop.ts`. The Zig loop is
implemented in `agent_loop.zig` with the same high-level shape, but this file is
the source note for the current Zig state ownership and transition contract.

Related review items are tracked in `zig/docs/review/03_agent_layer.md` and
`zig/docs/review/07_refactor_roadmap.md` under M7/ISS-412. This document is
descriptive only: it records the current behavior and ownership boundaries so
later M7 guard changes can add assertions without changing public behavior.

## Public shape

- `agent.zig` owns the stateful `Agent` facade: persistent message history,
  pending steering/follow-up queues, subscribers, currently streaming message,
  pending tool-call ids, and the active abort signal.
- `agent_loop.zig` owns the stateless execution mechanism. `runAgentLoop`
  receives prompts, a context snapshot, callbacks, and an optional stream
  function; it returns the messages added during that run and reports all
  observable progress through `AgentEvent`.
- `types.zig` owns the data contracts and callback signatures shared by both
  layers.

## State machine

Text-only diagram of the Zig `runAgentLoop` state machine:

```text
Caller
  |
  v
agent_start
  |
  v
turn_start
  |
  v
append initial prompts
  |  for each prompt: message_start -> message_end
  v
+--------------------------- outer loop ----------------------------+
|                                                                   |
|  has_more_tool_calls = true                                       |
|  pending = drain_steering_queue()                                 |
|                                                                   |
|  +------------------------- inner loop -------------------------+  |
|  | while has_more_tool_calls or pending is non-empty            |  |
|  |                                                             |  |
|  |  next turn? -> turn_start                                  |  |
|  |                                                             |  |
|  |  pending steering messages?                                |  |
|  |    append each as user message                             |  |
|  |    emit message_start -> message_end                       |  |
|  |                                                             |  |
|  |  streamAssistantResponse                                   |  |
|  |    provider start        -> message_start(assistant)       |  |
|  |    text_start/delta/end  -> accumulator -> message_update  |  |
|  |    thinking_*           -> accumulator -> message_update   |  |
|  |    toolcall_*           -> accumulator -> message_update   |  |
|  |    done/error_event     -> message_end(assistant)          |  |
|  |                                                             |  |
|  |  assistant stop_reason is error or aborted?                |  |
|  |    turn_end(tool_results = []) -> agent_end -> return      |  |
|  |                                                             |  |
|  |  collect assistant tool_calls                              |  |
|  |                                                             |  |
|  |  no tool calls?                                            |  |
|  |    turn_end -> should_stop_after_turn -> check abort       |  |
|  |      -> drain steering                                     |  |
|  |                                                             |  |
|  |  tool calls?                                               |  |
|  |    for each tool_call: tool_execution_start                |  |
|  |    prepare_arguments -> before_tool_call                   |  |
|  |      missing tool / validation error / before block         |  |
|  |        -> immediate error result                           |  |
|  |      otherwise                                             |  |
|  |        -> execute sequentially or in parallel               |  |
|  |           tool_execution_update* may occur during execute   |  |
|  |        -> after_tool_call                                  |  |
|  |    emit tool_execution_end                                 |  |
|  |    emit tool_result message_start -> message_end           |  |
|  |    append tool_result messages                             |  |
|  |    turn_end -> should_stop_after_turn -> check abort       |  |
|  |      -> drain steering                                     |  |
|  |                                                             |  |
|  +-------------------------------------------------------------+  |
|                                                                   |
|  inner loop idle? drain follow_up_queue()                         |
|    non-empty -> use as pending and continue outer loop             |
|    empty     -> agent_end -> return                               |
|                                                                   |
+-------------------------------------------------------------------+
```

Abort and error exits are terminal for the current run:

- Provider `.error_event` or an assistant message with `stop_reason =
  .error_reason` emits `message_end(assistant)`, then `turn_end`, then
  `agent_end`.
- Provider/tool cancellation is cooperative. The caller-owned atomic signal is
  passed to the provider stream and tool `execute` callbacks. `runLoop` also
  checks the signal after each `turn_end` and exits with `agent_end`.
- Tool failures are not loop failures. They become error tool-result messages,
  are appended to the transcript, and the loop can continue with another LLM
  call.

TypeScript has a few loop policies that Zig does not currently expose as direct
agent-loop controls, including `agentLoopContinue` and dynamic `getApiKey`.
Those are not part of this module's current state machine; adding them should
be treated as behavior work, not as documentation cleanup.

Blocked or executed tool results may set `terminate`. The loop stops after the
current tool batch only when every finalized result in that batch has
`terminate = true`. `Agent.reset()` rejects with `error.AgentBusy` while a run
is active.

## Major transition details

### Prompt acceptance

`runAgentLoop` emits `agent_start` and one initial `turn_start`, appends each
prompt to the run-local context, and emits `message_start`/`message_end` for
each prompt before the first LLM call.

### Steering and follow-up queues

The loop has two queue injection points:

- Steering messages are drained before an assistant response. They interrupt
  the active task between turns.
- Follow-up messages are drained only when the assistant would otherwise stop
  because there are no pending tool calls and no steering messages.

`Agent` owns the queues and exposes them to `runLoop` through
`get_steering_messages` and `get_follow_up_messages` callbacks. Queue drain
mode (`all` or `one_at_a_time`) is an `Agent` facade policy; `agent_loop.zig`
only sees the already-drained messages.

### Assistant streaming

`streamAssistantResponse` is the only state that translates provider streaming
events into agent events:

1. Optional `transform_context` rewrites agent messages.
2. Required `convert_to_llm` maps the current agent context to `pi-types.Message`.
3. The configured `StreamFn` (injected by the host; no default model-plane call) returns an
   `AssistantMessageEventStream`.
4. `PartialAssistantAccumulator` applies `text_*`, `thinking_*`, and
   `toolcall_*` events by provider `content_index`.
5. Each partial update emits `message_update` with a temporary assistant
   message.
6. `.done` and `.error_event` finalize the assistant with `message_end`.

If a provider emits tool-call deltas before a provider-level start event,
`streamAssistantResponse` creates a minimal assistant template using the
configured model metadata so partial updates can still be emitted.

### Tool execution

Tool execution starts only after the assistant message has ended and its
tool calls have been collected.

The per-tool pipeline is:

```text
tool_execution_start
  -> prepare_arguments
  -> before_tool_call
     -> immediate blocked/error result
     -> execute callback
        -> tool_execution_update*
  -> after_tool_call
  -> tool_execution_end
  -> tool_result message_start
  -> tool_result message_end
```

The whole batch runs sequentially if `config.tool_execution` is `.sequential`
or any tool in the batch is marked `.sequential`; otherwise prepared calls run
on worker threads. Parallel mode has two distinct ordering contracts:

- `tool_execution_update` can arrive while tools are still running. Worker
  updates are serialized through `ParallelToolEmitter` before invoking the
  shared event callback.
- Prepared tools record their execution completion order. Zig runs
  `after_tool_call` and emits `tool_execution_end` in that completion order,
  matching the TypeScript agent contract. Tool-result message artifacts
  (`message_start`/`message_end` for `tool_result`) and the `turn_end`
  `tool_results` slice are still emitted in assistant source order so the
  transcript and next LLM context remain stable.

Immediate preflight outcomes (missing tool or `before_tool_call` blocking) are
finalized during the sequential preflight phase. Their tool-result messages are
still held in source-order slots and emitted with the rest of the batch's
tool-result artifacts.

## State ownership boundaries

### Persistent state

`Agent` owns persistent state:

- `messages`
- `steering_queue` and `follow_up_queue`
- `listeners`
- `pending_tool_calls`
- `streaming_message`
- `active_abort_signal` pointer while a run is active

`Agent.processEvent` clones or records event data it needs to retain. Other
event subscribers must do the same; event payloads should be treated as
borrowed for the duration of the callback.

### Run-local state

`runAgentLoop` owns only run-local containers:

- `current_messages`, the context snapshot plus messages added during the run
- `new_messages`, the returned list of messages added during the run
- `pending_messages`, the current drained steering/follow-up slice
- `tool_results`, the current turn's tool-result slice

The loop does not own the caller's original context, tools, or callback
closures. The optional abort signal is borrowed from the caller.

### Streaming partial state

`PartialAssistantAccumulator` owns the buffers used to assemble partial
assistant content. It maps provider `content_index` values to local block
indices with `index_map`, owns text/thinking byte buffers, and owns cloned final
tool calls stored in partial tool-call blocks. It is deinitialized on every
exit from `streamAssistantResponse`, including error and abort paths.

`emitPartialMessageUpdate` builds each update payload in a per-callback arena.
The arena owns the temporary message shape, including the `content` slice and
any temporary parsed JSON for partial tool-call arguments. The accumulator owns
longer-lived partial bytes, such as text/thinking buffers and cloned final tool
calls, with the parent allocator. Even when a field happens to point at
accumulator-owned memory, the public event contract is intentionally stricter:
every pointer inside a `message_update` payload is borrowed and valid only until
the emit callback returns. Consumers that retain any update data must clone it
inside the callback. The `ISS-407 message_update payload is callback-scoped and
retained consumers clone` regression test is the canary for this
arena-vs-parent-allocator policy.

### Tool state

`PreparedToolCall` owns prepared JSON arguments and must deinitialize them after
execution/finalization. Tool definitions and `execute_context` are borrowed from
the caller's tool registry.

Sequential tool results are emitted directly from the current call path.
Parallel tool executions use one `ArenaAllocator` per worker task; result
content that must survive task cleanup is cloned into the parent allocator
before finalization. `finalizeExecutedToolCall` tracks whether result content is
owned so an `after_tool_call` override can replace content without double-freeing
the original.

### Event stream boundary

Events are the module's only observable output. The loop does not render UI,
persist sessions, or print diagnostics. Callers subscribe to:

- lifecycle events: `agent_start`, `agent_end`, `turn_start`, `turn_end`
- message events: `message_start`, `message_update`, `message_end`
- tool events: `tool_execution_start`, `tool_execution_update`,
  `tool_execution_end`

This keeps policy decisions (TUI rendering, session storage, telemetry, retry
handling) outside the loop and makes state-machine tests local to
`agent_loop.zig`.
