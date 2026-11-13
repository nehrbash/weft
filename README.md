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

Dependencies are Guile 3, guile-ares-rs, guile-json and guile-websocket; Cellar supplies
`guile-weft`. `(weft cli)` exports `main` with `#:initialize`, receiving the
workspace module at creation. `(weft runtime)` exports `make-workspace`,
`workspace-evaluate`, `workspace-tick!` and `workspace-close`. `(weft mcp)` accepts
an externally owned `#:evaluate` callback taking code and seconds.

MCP 2025-11-25 accepts `code` and optional `seconds`, defaulting to 30 and limited
to 50. Output is bounded. Evaluation deadlines are cooperative and do not roll
back effects or cancel jobs. The maintenance REPL has local-user authority;
the isolated room below is a separate endpoint. Neither protects against a
host process already running with the owner's account privileges.

## Recovery and advice

Set `WEFT_STATE_FILE` to a file in a private directory before starting `weft daemon`.
Snapshots are written atomically before replies. Explicit definitions, values,
zones, advice, event hooks, agent session IDs and inbox messages survive restart.
Pending turns become `interrupted`; queued events and external effects are not
replayed. A generation change identifies a new runtime. Jobs and ordinary heap
values are process-local.

```scheme
(saved-define! 'double '(lambda (x) (* x 2)))
(saved-set! 'count 21)
(saved-list)
(saved-remove! 'count)
(define (trace-evaluation code) (display "evaluating\n"))
(advice-add! 'trace 'workspace-evaluate 'before 'trace-evaluation)
(advice-list)
(advice-remove! 'trace)
```

Saved expressions run during recovery; keep them free of external effects.
Use `saved-set!` again to persist an updated value. `before`, `after` and `around`
advice resolve named procedures at invocation. Around advice receives a
zero-argument continuation followed by the original arguments. Targets include
`workspace-evaluate`, `workspace-tick`, and names invoked through `command-invoke`
or event dispatch. Save advised procedures explicitly for restart recovery.

## Isolated room and owner console

```sh
weft room-daemon
weft connect-room
weft room-eval '(zone-set! (quote status) (quote text) "Ready")'
weft owner view
```

The room requires Linux user namespaces and Bubblewrap. Its long-lived worker
has restricted Scheme bindings, read-only runtime sources and `/gnu/store`, a
private temporary directory, and isolated process/network namespaces. It has no
home directory, owner token, session bus, or host workspace socket. Evaluation
has allocation and time limits; the worker has a 1 GiB address-space ceiling.
The host broker stores explicit definitions, values and zones under
`$XDG_STATE_HOME/weft/room.scm` (default `~/.local/state/weft/room.scm`).
Ordinary definitions survive connections but not worker restarts.

Load `elisp/weft.el` and run `M-x weft-console`. The Guix package installs it
on Emacs's site load path. The native console renders text, metrics, tables and
wiring, lets the owner reorder zones, and shows exact effect requests with
Approve/Reject controls. `g` refreshes, `e` evaluates Scheme, `m` moves a zone
first, and `s` lists existing sessions. Rendering never evaluates zone content.

```scheme
(zone-set! 'counts 'table '(("State" "Count") ("Ready" 3)))
(zone-set! 'flow 'wiring '(("build" "review") ("review" "owner")))
(effect-propose! 'notify "Build completed")
(effect-propose! 'write-file '("/absolute/new-file.txt" "Exact contents\n"))
(effect-propose! 'run '("/absolute/project" ("make" "check")))
(effect-propose! 'session-send '("codex:THREAD-ID" "Inspect the failed build"))
```

Proposals cannot execute from the isolated evaluator. Owner decisions use a
private 256-bit capability held outside the worker and must match the entire
immutable proposal. Each approval is single-use. The broker records `executing`
before calling a connector; interrupted effects require a fresh owner decision
on a new proposal. Creation of files is exclusive: existing files are never
overwritten. Commands use literal argv, run for at most 40 seconds and return
bounded output. Archive decided requests from the console to free history space.

The CLI alternative is `weft owner approve ID '(TYPE PAYLOAD)'` or `reject`.
`weft owner inspect` returns the snapshot; `weft owner view` returns JSON.
Owner credentials are local-user capabilities, not protection against other
programs running as that user. Do not give isolated clients the maintenance
endpoint or owner-token file.

## Existing sessions and completion messages

`session-send` accepts an existing Emacs ACP buffer name or `codex:THREAD-ID`.
ACP delivery preserves unsent user input and queues behind busy turns. Native
Codex delivery uses its existing app-server control socket and task queue,
without replacing the model or permissions. It does not type into terminals.
`weft codex-list` lists native tasks; the console lists both adapter types.
Sending to a session is an approved effect; receipt means queued, not completed.

Configure a Claude or Codex `Stop` command hook as `weft notify-hook claude` or
`weft notify-hook codex`. The hook consumes JSON on stdin and posts a bounded
completion message to the maintenance workspace's owner inbox. Configure
`owner-notify!` there for desktop delivery. Merely connecting an MCP client
does not enable automatic completion messages.

GPL-3.0-or-later. See `LICENSE`.
