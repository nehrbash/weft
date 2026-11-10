(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (weft mcp)
             (weft runtime)
             (weft daemon)
             (ice-9 ftw)
             (json)
             (srfi srfi-64))
(define root
  (dirname (dirname (canonicalize-path (current-filename)))))
(define server
  (open-pipe* OPEN_BOTH
              "guile"
              "--no-auto-compile"
              "-L"
              (string-append root "/modules")
              "-s"
              (string-append root "/bin/weft")))
(define sequence
  0)
(define (request method params)
  (set! sequence
        (+ sequence 1))
  (scm->json `((jsonrpc . "2.0") (id unquote sequence)
               (method unquote method)
               (params unquote params)) server)
  (newline server)
  (force-output server)
  (let ((reply (json-string->scm (read-line server))))
    (unless (equal? sequence
                    (assoc-ref reply "id"))
      (error "Response ID mismatch" reply)) reply))
(define (evaluate code . timeout)
  (let* ((reply (request "tools/call"
                         `((name . "evaluate") (arguments (code unquote code)
                                                          ,@(if (pair? timeout)
                                                                `((seconds
                                                                   unquote
                                                                   (car
                                                                    timeout)))
                                                                '())))))
         (result (assoc-ref reply "result"))
         (content (assoc-ref result "content")))
    (call-with-input-string (assoc-ref (vector-ref content 0) "text") read)))
(test-begin "weft")
(define runner
  (test-runner-current))
(test-equal "requires initialization" -32002
            (assoc-ref (assoc-ref (request "tools/list"
                                           '()) "error") "code"))
(test-equal "negotiates protocol" "2025-11-25"
            (assoc-ref (assoc-ref (request "initialize"
                                           '((protocolVersion . "2025-11-25")))
                                  "result") "protocolVersion"))
(test-equal "single Scheme tool" 1
            (vector-length (assoc-ref (assoc-ref (request "tools/list"
                                                          '()) "result")
                                      "tools")))
(define initial
  (evaluate "(define answer 40) answer"))
(test-equal "definition result" "40"
            (assq-ref initial
                      'value))
(define next
  (evaluate "(+ answer 2)"))
(test-equal "definitions persist" "42"
            (assq-ref next
                      'value))
(test-equal "stable generation"
            (assq-ref initial
                      'generation)
            (assq-ref next
                      'generation))
(test-equal "stdout captured" "hello"
            (assq-ref (evaluate "(display \"hello\")")
                      'output))
(test-equal "errors are reported"
            'error
            (assq-ref (evaluate "(error \"fixture\")")
                      'status))
(test-equal "session recovers after error" "40"
            (assq-ref (evaluate "answer")
                      'value))
(test-equal "deadline interrupts Scheme"
            'timeout
            (assq-ref (evaluate "(let loop () (loop))" 0.1)
                      'status))
(test-equal "session recovers after deadline" "40"
            (assq-ref (evaluate "answer")
                      'value))
(define large
  (evaluate "(display (make-string 20000 #\\x)) (make-string 20000 #\\y)"))
(test-assert "large output is explicitly truncated"
             (assq-ref large
                       'truncated))
(test-assert "output size bounded"
             (<= (string-length (assq-ref large
                                          'output)) 16000))
(test-assert "value size bounded"
             (<= (string-length (assq-ref large
                                          'value)) 16000))
(test-equal "child output cannot corrupt protocol" "7"
            (assq-ref (evaluate "(system* \"printf\" \"native-output\\n\") 7")
                      'value))
(test-equal "guide available in runtime"
            'ok
            (assq-ref (evaluate "(workspace-help)")
                      'status))
(test-equal "runtime identity is discoverable"
            'ok
            (assq-ref (evaluate "(workspace-state)")
                      'status))
(test-equal "unknown tool rejected" -32602
            (assoc-ref (assoc-ref (request "tools/call"
                                           '((name . "missing") (arguments
                                                                           (code . "1"))))
                                  "error") "code"))
(test-equal "oversized deadline rejected" -32602
            (assoc-ref (assoc-ref (request "tools/call"
                                           '((name . "evaluate") (arguments
                                                                            (code . "1")
                                                                            (seconds . 51))))
                                  "error") "code"))
(test-equal "non-object arguments rejected" -32602
            (assoc-ref (assoc-ref (request "tools/call"
                                           '((name . "evaluate") (arguments . 7)))
                                  "error") "code"))
(test-equal "false deadline rejected" -32602
            (assoc-ref (assoc-ref (request "tools/call"
                                           '((name . "evaluate")
                                             (arguments (code . "1") (seconds . #f))))
                                  "error") "code"))
(define (value code)
  (let ((evaluation (evaluate code)))
    (unless (eq? 'ok (assq-ref evaluation 'status))
      (error "Evaluation failed" evaluation))
    (call-with-input-string (assq-ref evaluation 'value) read)))
(test-equal "workspace command can be defined" 41
            (value "(define (adjust n) (+ n 1)) (adjust answer)"))
(test-equal "workspace command can be redefined across calls" 42
            (value "(define (adjust n) (+ n 2)) (adjust answer)"))
(let* ((path (string-copy "/tmp/weft-extension-XXXXXX"))
       (port (mkstemp! path)))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (display "(define (extension-answer) (adjust answer))\n" port)
      (close-port port)
      (test-equal "extension loads into the live workspace" 42
                  (value (string-append "(primitive-load " (object->string path)
                                        ") (extension-answer)")))
      (test-equal "extension and existing state persist" '(40 42)
                  (value "(list answer (extension-answer))")))
    (lambda ()
      (unless (port-closed? port) (close-port port))
      (delete-file path))))
(define (elapsed start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))
(define started (get-internal-real-time))
(define job (value "(define sleeper (assq-ref (job-start '(\"sleep\" \"30\")) 'id)) (job-status sleeper)"))
(test-equal "job starts running" 'running (assq-ref job 'state))
(test-assert "job start returns promptly" (< (elapsed started) 5))
(test-equal "evaluation remains usable during job" 42 (value "(+ answer 2)"))
(set! started (get-internal-real-time))
(test-equal "bounded wait leaves job running" 'running
            (assq-ref (value "(job-wait sleeper 0.1)") 'state))
(test-assert "job wait returns promptly" (< (elapsed started) 5))
(test-equal "cancel reaches terminal state" 'cancelled
            (assq-ref (value "(job-cancel sleeper)") 'state))
(test-assert "terminal job can be forgotten" (value "(job-forget sleeper)"))
(test-equal "forgotten job absent" '() (value "(job-list)"))
(define finished
  (value "(define printer (assq-ref (job-start '(\"sh\" \"-c\" \"printf job-output; printf job-error >&2\")) 'id)) (job-wait printer 5)"))
(test-equal "job output isolated from protocol" "job-output" (assq-ref finished 'stdout))
(test-equal "job stderr captured" "job-error" (assq-ref finished 'stderr))
(test-equal "successful exit reported" 0 (assq-ref finished 'exit-code))
(test-assert "completed job can be forgotten" (value "(job-forget printer)"))
(define shutdown-job
  (value "(job-start '(\"sleep\" \"30\"))"))
(define child-pid (assq-ref shutdown-job 'pid))
(test-assert "shutdown fixture reports child PID" (integer? child-pid))
(close-pipe server)
(test-assert "EOF cancels and reaps managed child"
             (and child-pid
                  (catch 'system-error
                    (lambda () (kill child-pid 0) #f)
                    (lambda args (= ESRCH (system-error-errno args))))))
(let* ((output (open-output-string))
       (requests
        (string-append
         (scm->json-string '((jsonrpc . "2.0") (id . 1) (method . "initialize"))) "\n"
         (scm->json-string '((jsonrpc . "2.0") (id . 2) (method . "tools/call")
                            (params (name . "evaluate") (arguments (code . "1"))))) "\n"
         (scm->json-string '((jsonrpc . "2.0") (id . 3) (method . "ping"))) "\n")))
  (serve-mcp (open-input-string requests) output
             #:evaluate (lambda (code seconds) (error "Daemon unavailable")))
  (call-with-input-string (get-output-string output)
    (lambda (input)
      (read-line input)
      (let ((failure (json-string->scm (read-line input)))
            (ping (json-string->scm (read-line input))))
        (test-assert "forwarding failure is a tool error"
                     (assoc-ref (assoc-ref failure "result") "isError"))
        (test-equal "forwarding failure retains request ID" 2 (assoc-ref failure "id"))
        (test-equal "bridge accepts requests after forwarding failure" 3 (assoc-ref ping "id"))))))
(let ((workspace (make-workspace)))
  (define (client code)
    (let* ((requests
            (string-append
             (scm->json-string '((jsonrpc . "2.0") (id . 1) (method . "initialize"))) "\n"
             (scm->json-string `((jsonrpc . "2.0") (id . 2) (method . "tools/call")
                                (params (name . "evaluate") (arguments (code . ,code))))) "\n"))
           (output (open-output-string)))
      (serve-mcp (open-input-string requests) output
                 #:evaluate (lambda (source seconds)
                              (workspace-evaluate workspace source #:seconds seconds)))
      (call-with-input-string (get-output-string output)
        (lambda (input)
          (read-line input)
          (let* ((reply (json-string->scm (read-line input)))
                 (content (assoc-ref (assoc-ref reply "result") "content")))
            (call-with-input-string (assoc-ref (vector-ref content 0) "text") read))))))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (let ((first (client "(define shared-value 41) (define pending (assq-ref (job-start '(\"sleep\" \"30\")) 'id)) shared-value"))
            (second (client "(+ shared-value 1)")))
        (test-equal "second bridge sees shared definitions" "42" (assq-ref second 'value))
        (test-equal "bridges share workspace generation"
                    (assq-ref first 'generation) (assq-ref second 'generation))
        (test-equal "bridge EOF leaves shared jobs alive" "running"
                    (assq-ref (client "(assq-ref (job-status pending) 'state)") 'value))))
    (lambda () (workspace-close workspace))))
(let* ((directory (mkdtemp "/tmp/weft-bridge-XXXXXX"))
       (path (string-append directory "/workspace.sock"))
       (child #f) (first #f) (second #f))
  (define (bridge)
    (open-pipe* OPEN_BOTH "guile" "--no-auto-compile" "-L"
                (string-append root "/modules") "-s" (string-append root "/bin/weft")
                "connect" path))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (force-output)
      (set! child (primitive-fork))
      (when (zero? child)
        (execlp "guile" "guile" "--no-auto-compile" "-L"
                (string-append root "/modules") "-s" (string-append root "/bin/weft")
                "daemon" path))
      (let loop ((remaining 100))
        (unless (and (file-exists? path)
                     (catch #t (lambda () (remote-evaluate path "#t") #t)
                            (lambda args #f)))
          (when (zero? remaining) (error "Bridge fixture daemon did not start"))
          (usleep 20000)
          (loop (- remaining 1))))
      (set! first (bridge))
      (set! server first)
      (request "initialize" '())
      (let ((initial (evaluate "(define shared-counter 12) shared-counter")))
        (set! second (bridge))
        (set! server second)
        (request "initialize" '())
        (test-equal "second stdio process reads first process definition" 12
                    (value "shared-counter"))
        (test-equal "stdio processes share daemon generation"
                    (assq-ref initial 'generation)
                    (assq-ref (evaluate "shared-counter") 'generation))
        (value "(set! shared-counter 13) shared-counter")
        (set! server first)
        (test-equal "first stdio process sees second process mutation" 13
                    (value "shared-counter"))
        (close-pipe first)
        (set! first #f)
        (set! server second)
        (test-equal "stdio disconnect preserves daemon state" 13
                    (value "shared-counter"))))
    (lambda ()
      (when first (close-pipe first))
      (when second (close-pipe second))
      (when child (kill child SIGTERM) (waitpid child))
      (when (file-exists? path) (delete-file path))
      (when (file-exists? (string-append path ".lock"))
        (delete-file (string-append path ".lock")))
      (rmdir directory))))
(test-end "weft")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
