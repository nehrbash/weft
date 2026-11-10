# Weft

Weft is a live Scheme workspace for people and agents. One MCP `evaluate` tool
accepts code. Definitions, subprocess jobs, event hooks and agent sessions belong
to the workspace host. A local daemon shares them across client connections.

Define or redefine functions in later calls, or load an extension with
`(primitive-load "/absolute/path/extension.scm")`. Existing values remain
available. `workspace-help`, `workspace-state` and `procedure-documentation`
provide discovery; `room-help` and `room-state` remain compatibility aliases.

## Run

```sh
guix shell -m manifest.scm -- bin/weft daemon
# In other terminals, or configured as the MCP server command:
guix shell -m manifest.scm -- bin/weft connect
guix shell -m manifest.scm -- bin/weft eval '(workspace-state)'
guix shell -m manifest.scm -- make check
```

The default socket is `$XDG_RUNTIME_DIR/weft/workspace.sock`, falling back to
`/tmp/weft-UID/workspace.sock`. `daemon`, `connect` and `eval` accept an explicit
socket path. Its parent must be private to the current user; the daemon creates
it if missing. Any process running as that user can evaluate with their authority.

`weft` or `weft standalone` serves an independent stdio workspace. Standalone
orchestration advances after requests; the daemon also dispatches while idle.
The daemon serializes Scheme evaluations and hook execution. Disconnecting a
bridge leaves its shared workspace running. Stopping the host closes its jobs.

## Jobs and agents

```scheme
(define build (assq-ref (job-start '("make" "check")) 'id))
(job-status build)
(job-wait build 1)
(job-list)
(job-cancel build)
(job-forget build)

(agent-register! 'reviewer 'codex #:cwd "/absolute/project")
(agent-register! 'writer 'claude #:cwd "/absolute/project")
(define review (agent-send! 'reviewer "Inspect the test failures and report findings."))
(turn-status review)
(owner-messages)
```

Jobs take argv without shell expansion and report bounded stdout/stderr tails.
`job-wait` waits at most 10 seconds; an expired wait leaves the job alive.
`job-forget` accepts terminal jobs. Jobs require Linux. Cancellation kills the
managed process group and reaps its direct child. Descendants that escape the
group and abrupt host termination are outside that cleanup guarantee.

Agents run owned headless CLI sessions using installed `codex` or `claude` and
their existing authentication and permission settings. No permission-bypass
flags are added. Claude denies requests that would require an unattended prompt.
The first completed turn records the provider's session ID; subsequent turns
resume it. Turns for each agent run sequentially. `turn-cancel!` stops a turn.
These adapters do not inject messages into existing interactive sessions.

Provider output is captured up to 1 MiB. Truncation, malformed output, missing
completion/session information and process failures produce failed turns.
Replies and errors enter the bounded owner inbox; `owner-messages` accepts an
optional last-seen message ID. The inbox is not a desktop notification by itself.
The adapters use the documented [Codex JSONL interface](https://learn.chatgpt.com/docs/non-interactive-mode)
and [Claude JSON interface](https://code.claude.com/docs/en/headless).

## Events and live commands

```scheme
(command-register! 'review-event
  (lambda (event)
    (agent-send! 'reviewer (object->string (assq-ref event 'payload)))))
(event-on! 'review-build 'build-finished 'review-event)
(event-emit! 'build-finished "Tests failed; inspect the log." #:key "build-123")
(event-hooks)
```

Hooks resolve their command symbol when dispatched, so redefining a command
changes future handling without restarting. `event-off!` removes a hook.
Event keys deduplicate by source within the last 256 keyed events. Payloads must
print within 65,536 characters; keys are limited to 256 characters. The queue
holds at most 128 events, reserving space during dispatch for unfinished
subscribers. Event cascades stop after eight hops. Each hook has a cooperative
one-second deadline; failures enter the owner inbox without retrying that hook.
Use `command-list`, `turn-list` and `orchestration-state` to inspect work.
`owner-post!` adds a message; `owner-notify!` selects a command called with each
new owner message, or `#f` to disable delivery. For example:

```scheme
(command-register! 'desktop-message
  (lambda (message)
    (unless (zero? (system* "timeout" "0.5" "notify-send" "--"
                           "Weft" (assq-ref message 'text)))
      (error "Desktop notification failed"))))
(owner-notify! 'desktop-message)
```

The inbox retains the latest 256 messages, each limited to 16,384 characters.
Each tick invokes up to four event hooks and one notification callback. Pending
notifications retain the latest 256 messages and drop older deliveries on
overflow. Delivery is best effort; a failing callback is disabled and its error
enters the inbox. There is no automatic retry or durable delivery guarantee.

## Embedding and boundaries

Dependencies are Guile 3, guile-ares-rs and guile-json; Cellar supplies
`guile-weft`. `(weft cli)` exports `main` with `#:initialize`, receiving the
workspace module at creation. `(weft runtime)` exports `make-workspace`,
`workspace-evaluate`, `workspace-tick!` and `workspace-close`. `(weft mcp)` accepts
an externally owned `#:evaluate` callback taking code and seconds.

MCP 2025-11-25 accepts `code` and optional `seconds`, defaulting to 30 and limited
to 50. Output is bounded. Evaluation deadlines are cooperative and do not roll
back effects or cancel jobs. This trusted local runtime has no sandbox, approval
gate or database. State, queues, hooks, agent registrations and owner messages
are lost on host restart; `workspace-state` reports a new generation. Provider
CLI histories have their own persistence. Save reusable Scheme in source files.
Weft-specific advice APIs and interactive-session wakeup adapters are not implemented.

GPL-3.0-or-later. See `LICENSE`.
