(use-modules (weft agents) (weft jobs) (srfi srfi-64) (srfi srfi-1) (json))

(test-begin "agents")
(define runner (test-runner-current))
(define claude (provider-start-spec 'claude "event\ncontent" (getcwd) #f))
(define codex (provider-start-spec 'codex "event" (getcwd) #f))
(define resumed (provider-start-spec 'codex "event" (getcwd) "thread-1"))
(define (status output)
  `((state . exited) (exit-code . 0) (signal . #f) (truncated . #f) (stdout . ,output)))
(define (decode spec output) (provider-result spec (status output)))
(define claude-json
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"done\",\"session_id\":\"session-1\"}")
(define codex-json
  (string-append "{\"type\":\"thread.started\",\"thread_id\":\"thread-1\"}\n"
                 "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}\n"
                 "{\"type\":\"turn.completed\"}\n"))
(test-equal "prompt is stdin data" "event\ncontent" (assq-ref claude 'stdin))
(test-equal "explicit working directory" (getcwd) (assq-ref codex 'cwd))
(test-equal "bounded complete capture" 1048576 (assq-ref codex 'capture-limit))
(test-equal "Codex start argv" '("codex" "exec" "--json" "-") (assq-ref codex 'argv))
(test-equal "Codex resume argv" '("codex" "exec" "resume" "thread-1" "--json" "-")
            (assq-ref resumed 'argv))
(test-equal "Claude resume uses explicit session"
            '("claude" "-p" "--output-format" "json" "--permission-prompts" "none"
              "--resume" "session-1")
            (assq-ref (provider-start-spec 'claude "event" (getcwd) "session-1") 'argv))
(test-assert "no provider permission bypass flags"
  (every (lambda (arg) (not (string-contains arg "bypass")))
         (append (assq-ref claude 'argv) (assq-ref codex 'argv))))
(test-error "unknown provider rejected" #t (provider-start-spec 'other "event" (getcwd) #f))
(test-error "relative cwd rejected" #t (provider-start-spec 'codex "event" "." #f))
(test-error "flag-like session rejected" #t (provider-start-spec 'codex "event" (getcwd) "--last"))
(test-equal "Claude session extracted" "session-1" (assq-ref (decode claude claude-json) 'session))
(test-equal "Claude result extracted" "done" (assq-ref (decode claude claude-json) 'text))
(test-equal "Codex session extracted" "thread-1" (assq-ref (decode codex codex-json) 'session))
(test-equal "Codex result extracted" "done" (assq-ref (decode codex codex-json) 'text))
(test-assert "malformed output fails" (assq-ref (decode claude "not json") 'error))
(test-assert "missing Claude session fails"
  (assq-ref (decode claude "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\"}") 'error))
(test-assert "Claude error result fails"
  (assq-ref (decode claude "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true}") 'error))
(test-assert "unfinished Codex turn fails"
  (assq-ref (decode codex "{\"type\":\"thread.started\",\"thread_id\":\"t\"}") 'error))
(test-assert "Codex failure event fails"
  (assq-ref (decode codex (string-append codex-json "{\"type\":\"turn.failed\"}\n")) 'error))
(test-assert "truncated output never parses"
  (assq-ref (provider-result claude (acons 'truncated #t (status claude-json))) 'error))
(test-assert "nonzero provider exit fails"
  (assq-ref (provider-result claude (acons 'exit-code 1 (status claude-json))) 'error))
(test-assert "changed session on resume fails"
  (assq-ref (decode (provider-start-spec 'claude "event" (getcwd) "different") claude-json) 'error))
(let* ((directory (string-copy "/tmp/weft-provider-XXXXXX"))
       (temporary (mkstemp! directory))
       (manager (make-job-manager)))
  (close-port temporary)
  (delete-file directory)
  (mkdir directory #o700)
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (for-each
       (lambda (provider)
         (let* ((path (string-append directory "/" (symbol->string provider)))
                (spec (provider-start-spec provider "fixture input\nsecond line" directory #f)))
           (call-with-output-file path
             (lambda (port)
               (format port "#!~a --no-auto-compile\n!#\n" (readlink "/proc/self/exe"))
               (write '(use-modules (json) (ice-9 textual-ports)) port)
               (newline port)
               (write '(define text (object->string
                                     (list (getcwd) (get-string-all (current-input-port))))) port)
               (newline port)
               (write
                (if (eq? provider 'claude)
                    '(scm->json `((type . "result") (subtype . "success") (is_error . #f)
                                  (result . ,text) (session_id . "fixture-session")))
                    '(for-each (lambda (event) (scm->json event) (newline))
                               (list '((type . "thread.started") (thread_id . "fixture-session"))
                                     `((type . "item.completed") (item (type . "agent_message") (text . ,text)))
                                     '((type . "turn.completed"))))) port)
               (newline port)))
           (chmod path #o700)
           (let* ((job (job-start manager (cons path (cdr (assq-ref spec 'argv)))
                                  #:cwd (assq-ref spec 'cwd) #:stdin (assq-ref spec 'stdin)
                                  #:output-limit (assq-ref spec 'capture-limit)))
                  (result (provider-result spec (job-wait manager (assq-ref job 'id) 5))))
             (test-equal (string-append (symbol->string provider) " fixture process succeeds")
                         #f (assq-ref result 'error))
             (test-equal (string-append (symbol->string provider) " receives cwd and complete stdin")
                         (list directory "fixture input\nsecond line")
                         (call-with-input-string (assq-ref result 'text) read))
             (test-equal (string-append (symbol->string provider) " preserves actual session ID")
                         "fixture-session" (assq-ref result 'session)))))
       '(claude codex)))
    (lambda ()
      (jobs-close manager)
      (for-each (lambda (name)
                  (let ((path (string-append directory "/" name)))
                    (when (file-exists? path) (delete-file path)))) '("claude" "codex"))
      (rmdir directory))))
(test-end "agents")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
