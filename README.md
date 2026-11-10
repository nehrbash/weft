# Weft

Weft is a persistent Scheme workspace for people and agents. One MCP `evaluate`
tool accepts code; definitions and intermediate values stay in the server process.
Managed subprocess jobs keep running between evaluations.

Define or redefine functions in later calls, or load an extension into the live
workspace with `(primitive-load "/absolute/path/extension.scm")`. Existing values
remain available; extensions can use them and add commands without restarting.
Use `workspace-state` to inspect workspace identity and `(job-list)` for jobs.

```scheme
(workspace-help)
(workspace-state)
(define values '(3 5 8))
(apply + values)
(define build (assq-ref (job-start '("make" "check")) 'id))
(job-status build)
(job-wait build 1)
(job-list)
```

`job-start` takes an argv list without shell expansion. Status includes the job
ID, state, exit information and bounded stdout/stderr tails. `job-wait` waits at
most 10 seconds and leaves a running job alive when its wait expires.
`job-cancel` terminates the managed process group and reaps the child;
`job-forget` removes a terminal job. Closing the workspace, including stdio EOF
or a server error that unwinds the request loop, cancels remaining jobs and reaps
their direct children. Jobs require Linux and run subprocesses, not concurrent
Scheme evaluations. Cleanup covers the managed process group; descendants that
escape it and abrupt server termination are outside that guarantee.

The runtime uses Guile and Ares evaluation. It captures Scheme output, reports
exceptions, bounds returned text, and supports cooperative evaluation deadlines.
The MCP 2025-11-25 stdio tool accepts `code` and optional `seconds`, defaulting to
30 and limited to 50. `room-help` and `room-state` remain compatibility aliases.

## Run and test

```sh
guix shell -m manifest.scm -- bin/weft
guix shell -m manifest.scm -- make check
```

Dependencies are Guile 3, guile-ares-rs and guile-json. Cellar supplies the
`guile-weft` package. Other programs can import `(weft mcp)` and call
`serve-stdio`, optionally passing `#:initialize` a function receiving the
workspace module. Embedders using `(weft runtime)` call `make-workspace`,
`workspace-evaluate` and `workspace-close` to release managed jobs.

## Current boundaries

This is a trusted local REPL with the invoking user's authority: no sandbox,
approval gate, shared daemon or database. Evaluation deadlines do not roll back
effects or cancel jobs. Unmanaged subprocesses remain the caller's responsibility.
Uncaptured child stdout goes to server stderr to protect the protocol.

State lasts within one server process. Restarting changes the generation reported
by `workspace-state` and loses definitions and job history. Separate clients start
separate workspaces. Save reusable code in source modules.
Weft-specific hooks and advice APIs are planned; they are not implemented.

GPL-3.0-or-later. See `LICENSE`.
