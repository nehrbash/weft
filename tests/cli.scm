(use-modules (weft cli) (weft daemon) (ice-9 popen) (ice-9 rdelim)
             (ice-9 ftw) (json) (srfi srfi-64))

(test-begin "cli")
(define runner (test-runner-current))
(define root (dirname (dirname (canonicalize-path (current-filename)))))
(define directory (mkdtemp "/tmp/weft-cli-XXXXXX"))
(define runtime (getenv "XDG_RUNTIME_DIR"))
(define state (getenv "XDG_STATE_HOME"))
(define socket-path (string-append directory "/weft/room.sock"))
(define child #f)

(define (start! command)
  (force-output)
  (set! child (primitive-fork))
  (when (zero? child)
    (catch #t
      (lambda () (primitive-exit (main (list command))))
      (lambda args
        (write args (current-error-port))
        (primitive-exit 1))))
  (let loop ((remaining 250))
    (unless (and (file-exists? socket-path)
                 (catch #t (lambda () (remote-evaluate socket-path "#t") #t)
                        (lambda _ #f)))
      (when (zero? remaining) (error "Workspace CLI did not start"))
      (usleep 20000)
      (loop (- remaining 1)))))

(define (stop!)
  (when child
    (kill child SIGTERM)
    (waitpid child)
    (set! child #f)))

(define (evaluate command code)
  (let* ((output (open-output-string))
         (status (parameterize ((current-output-port output))
                   (main (list command code))))
         (reply (call-with-input-string (get-output-string output) read)))
    (unless (zero? status) (error "CLI evaluation failed" reply))
    (call-with-input-string (assq-ref reply 'value) read)))

(define (bridge command)
  (let ((port (open-pipe* OPEN_BOTH "guile" "--no-auto-compile"
                        "-L" (string-append root "/modules")
                        "-s" (string-append root "/bin/weft") command)))
    (define (request id method params)
      (scm->json `((jsonrpc . "2.0") (id . ,id) (method . ,method)
                  (params . ,params)) port)
      (newline port)
      (force-output port)
      (assoc-ref (json-string->scm (read-line port)) "result"))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (test-equal "bridge identifies the workspace endpoint" "weft-workspace"
          (assoc-ref (assoc-ref (request 1 "initialize" '()) "serverInfo") "name"))
        (test-assert "bridge advertises a shared workspace"
          (string-contains
            (assoc-ref (vector-ref (assoc-ref (request 2 "tools/list" '()) "tools") 0)
                       "description")
            "Shared workspace"))
        (let* ((reply (request 3 "tools/call"
                       '((name . "evaluate")
                         (arguments (code . "(saved-ref 'cli-value)") (format . "record")))))
               (record (call-with-input-string
                         (assoc-ref (vector-ref (assoc-ref reply "content") 0) "text") read)))
          (test-equal "bridge reaches the same saved workspace" "42"
            (assq-ref record 'value))))
      (lambda () (close-pipe port)))))

(dynamic-wind
  (lambda ()
    (setenv "XDG_RUNTIME_DIR" directory)
    (setenv "XDG_STATE_HOME" directory))
  (lambda ()
    (start! "workspace-daemon")
    (evaluate "workspace-eval" "(saved-set! 'cli-value 42)")
    (test-equal "legacy evaluation shares canonical daemon state" 42
      (evaluate "room-eval" "(saved-ref 'cli-value)"))
    (test-assert "collaboration help names the configured endpoint"
      (string-contains (evaluate "workspace-eval" "(workspace-help 'collaboration)")
                       "weft-workspace"))
    (bridge "connect-workspace")
    (bridge "connect-room")
    (stop!)
    (start! "room-daemon")
    (test-equal "legacy daemon recovers canonical saved state" 42
      (evaluate "workspace-eval" "(saved-ref 'cli-value)")))
  (lambda ()
    (stop!)
    (if runtime (setenv "XDG_RUNTIME_DIR" runtime) (unsetenv "XDG_RUNTIME_DIR"))
    (if state (setenv "XDG_STATE_HOME" state) (unsetenv "XDG_STATE_HOME"))
    (file-system-fold (const #t)
      (lambda (path stat result) (delete-file path))
      (const #t)
      (lambda (path stat result) (rmdir path))
      (const #t)
      (lambda (path stat errno result) (error "Cannot clean CLI fixture" path errno))
      #t directory)))
(test-end "cli")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
