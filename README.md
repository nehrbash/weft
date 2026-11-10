# Weft

Weft is a persistent Scheme workspace for people and agents. Its MCP interface
accepts code through one `evaluate` tool. Definitions and intermediate values
stay in the process, so callers can compose functions and return small summaries.

```scheme
(room-help)
(room-state)
(define values '(3 5 8))
(apply + values)
```

The runtime uses Guile and Ares evaluation. It captures Scheme output, reports
exceptions, bounds returned text, and supports evaluation deadlines. It speaks
the MCP 2025-11-25 stdio protocol. The tool accepts `code` and an optional
`seconds` deadline, defaulting to 30 and limited to 50.

## Run and test

```sh
guix shell -m manifest.scm -- bin/weft
guix shell -m manifest.scm -- make check
```

Dependencies are Guile 3, guile-ares-rs and guile-json. Cellar supplies the
`guile-weft` package. Other programs can import `(weft mcp)` and call
`serve-stdio`, optionally passing `#:initialize` a function that receives the
workspace module. This keeps application-specific functions outside Weft.

## Current boundaries

Weft is a trusted local REPL with the invoking user's authority. It has no
sandbox or approval gate. Deadlines are cooperative, do not roll back effects,
and do not terminate child processes. Capture subprocess output explicitly;
uncaptured child stdout goes to server stderr to protect the protocol.

State persists between calls in one server process. A restart changes the
generation reported by `room-state` and loses unsaved definitions. Save reusable
code in source modules. Separate clients currently start separate workspaces.

## Direction

Weft is the first part of a shared, live-programmable room: an isolated runtime,
effect-typed connectors, exact approvals from an authenticated owner console,
and typed data rendered by trusted widgets. Shared participants, visible wiring,
render inspection and restart recovery belong to that roadmap. They are not
implemented by this REPL.

GPL-3.0-or-later. See `LICENSE`.
