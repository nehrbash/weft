(define-module (weft mcp)
  #:use-module (weft runtime)
  #:use-module (json)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:export (serve-mcp serve-stdio))

(define %tool
  '((name . "evaluate")
    (description . "Evaluate Guile Scheme in a persistent local workspace. Start with (room-help) and (room-state). Reuse variables and imported modules; return summaries. This trusted REPL runs with the local user's authority and has no sandbox or approval gate. Definitions last until this server process exits.")
    (inputSchema (type . "object")
                 (properties (code (type . "string")
                                   (maxLength . 131072))
                             (seconds (type . "number")
                                      (exclusiveMinimum . 0)
                                      (maximum . 50)))
                 (required . #("code"))
                 (additionalProperties . #f))
    (annotations (readOnlyHint . #f)
                 (destructiveHint . #t)
                 (idempotentHint . #f)
                 (openWorldHint . #t))))

(define (rpc-error id code message)
  `((jsonrpc . "2.0") (id unquote id)
    (error (code unquote code)
           (message unquote message))))

(define* (serve-mcp input output
                    #:key (initialize (lambda (module)
                                        #t)))
  "Serve newline-delimited MCP on INPUT and OUTPUT with process-local state."
  (define room
    (make-room #:initialize initialize))
  (define initialized?
    #f)
  (define (result id value)
    `((jsonrpc . "2.0") (id unquote id)
      (result unquote value)))
  (define (dispatch request)
    (let ((id (assoc-ref request "id"))
          (method (assoc-ref request "method"))
          (params (or (assoc-ref request "params")
                      '())))
      (cond
        ((not (equal? (assoc-ref request "jsonrpc") "2.0"))
         (rpc-error 'null -32600 "Expected JSON-RPC 2.0"))
        ((not (assoc "id" request))
         #f)
        ((equal? method "initialize")
         (set! initialized? #t)
         (result id
                 `((protocolVersion . "2025-11-25") (capabilities (tools
                                                                         (listChanged . #f)))
                   (serverInfo (name . "weft")
                               (version . "0.1.0"))
                   (instructions . "Use evaluate with Scheme source. Start with (room-help). State is process-local; check (room-state) after reconnecting. No browser, sandbox, shared server or durable state is implemented."))))
        ((equal? method "ping")
         (result id
                 '()))
        ((not initialized?)
         (rpc-error id -32002 "Initialize first"))
        ((equal? method "tools/list")
         (result id
                 `((tools unquote
                          (vector %tool)))))
        ((equal? method "tools/call")
         (let* ((arguments (or (assoc-ref params "arguments")
                               '()))
                (code (assoc-ref arguments "code"))
                (seconds (or (assoc-ref arguments "seconds") 30)))
           (if (and (equal? (assoc-ref params "name") "evaluate")
                    (string? code)
                    (<= (string-length code) 131072)
                    (real? seconds)
                    (> seconds 0)
                    (<= seconds 50)
                    (every (lambda (entry)
                             (member (car entry)
                                     '("code" "seconds"))) arguments))
               (let ((evaluation (room-evaluate room code
                                                #:seconds seconds)))
                 (result id
                         `((content unquote
                                    (vector `((type . "text") (text unquote
                                                                    (object->string
                                                                     evaluation)))))
                           (isError unquote
                                    (not (eq? 'ok
                                              (assq-ref evaluation
                                                        'status)))))))
               (rpc-error id -32602
                          "Expected evaluate with code and optional seconds"))))
        (else (rpc-error id -32601 "Unknown method")))))
  (let loop
    ()
    (let ((line (read-line input)))
      (unless (eof-object? line)
        (let ((reply (catch #t
                            (lambda ()
                              (let ((request (json-string->scm line)))
                                (if (and (list? request)
                                         (every pair? request))
                                    (dispatch request)
                                    (rpc-error 'null -32600
                                               "Expected one request object"))))
                            (lambda (key . args)
                              (rpc-error 'null -32700 "Invalid request")))))
          (when reply
            (scm->json reply output)
            (newline output)
            (force-output output)))
        (loop)))))

(define* (serve-stdio #:key (initialize (lambda (module)
                                          #t)))
  "Serve MCP on standard I/O, isolating protocol descriptors from child processes."
  ;; Child processes must not read requests or write into the protocol stream.
  (let* ((input (fdopen (dup 0) "r"))
         (output (fdopen (dup 1) "w"))
         (null (open-input-file "/dev/null")))
    (fcntl input F_SETFD FD_CLOEXEC)
    (fcntl output F_SETFD FD_CLOEXEC)
    (dup2 (fileno null) 0)
    (dup2 2 1)
    (serve-mcp input output
               #:initialize initialize)))
