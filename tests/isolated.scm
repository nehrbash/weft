(use-modules (weft isolated) (weft daemon) (weft state)
             (srfi srfi-64) (ice-9 rdelim))
(test-begin "isolated")
(define runner (test-runner-current))
(define directory (mkdtemp "/tmp/weft-room-test-XXXXXX"))
(define socket-path (string-append directory "/room.sock"))
(define state-path (string-append directory "/state.scm"))
(define token-path (string-append directory "/token"))
(define token (make-string 64 #\a))
(define child #f)
(call-with-output-file token-path (lambda (port) (display token port)))
(chmod token-path #o600)
(define (start!)
  (force-output)
  (set! child (primitive-fork))
  (when (zero? child)
    (catch #t
      (lambda ()
        (serve-isolated socket-path state-path token-path
          #:execute (lambda (type payload) (list type payload)))
        (primitive-exit 0))
      (lambda args (write args (current-error-port)) (newline (current-error-port)) (primitive-exit 1))))
  (let loop ((remaining 250))
    (unless (and (file-exists? socket-path)
                 (catch #t (lambda () (remote-evaluate socket-path "#t") #t) (lambda _ #f)))
      (when (zero? remaining) (error "Room did not start"))
      (usleep 20000) (loop (- remaining 1)))))
(define (stop!)
  (when child (kill child SIGTERM) (waitpid child) (set! child #f)))
(define (evaluate code) (remote-evaluate socket-path code))
(define (value code) (call-with-input-string (assq-ref (evaluate code) 'value) read))
(define (owner operation . args) (apply owner-request socket-path token operation args))
(dynamic-wind
  start!
  (lambda ()
    (test-equal "isolated evaluation" 42 (value "(+ 20 22)"))
    (test-equal "shared live definitions" 9 (begin (evaluate "(define x 9)") (value "x")))
    (for-each
      (lambda (code)
        (let ((reply (remote-evaluate socket-path code #:seconds 0.2)))
          (test-equal "blocking wait is rejected instead of holding the room" 'error
            (assq-ref reply 'status))
          (test-assert "blocking wait explains how peers can proceed"
            (string-contains (assq-ref reply 'value) "wait outside evaluate"))))
      '("(sleep 10)" "(usleep 10000000)"))
    (for-each
      (lambda (code)
        (test-equal (string-append "denies " code) 'error (assq-ref (evaluate code) 'status)))
      '("(open-input-file \"/etc/passwd\")" "(system* \"sh\")"
        "(socket AF_INET SOCK_STREAM 0)" "(use-modules (ice-9 popen))"
        "(@ (guile) system*)" "(@@ (guile) system*)"
        "(module-ref (resolve-module '(guile)) 'system*)"))
    (test-equal "forged owner channel rejected" 'error
      (assq-ref (owner-request socket-path "not-the-token" 'inspect) 'status))
    (test-equal "owner channel never runs the Scheme reader before authentication" 'error
      (assq-ref (evaluate "WEFT-OWNER #1@0:100000000()") 'status))
    (test-equal "broker survives malformed owner request" 42 (value "(+ 20 22)"))
    (test-equal "proposal has no automatic effect" "(1)"
      (assq-ref (evaluate "(effect-propose! 'notify \"approved text\")") 'proposals))
    (test-equal "changed payload cannot be approved" 'error
      (assq-ref (owner 'decide 1 '(notify "different text") 'approve) 'status))
    (test-equal "owner approves exact content" 'ok
      (assq-ref (owner 'decide 1 '(notify "approved text") 'approve) 'status))
    (test-equal "approval is single use" 'error
      (assq-ref (owner 'decide 1 '(notify "approved text") 'approve) 'status))
    (value "(saved-set! 'durable 17)")
    (value "(zone-set! 'status 'text \"ready\")")
    (value "(zone-set! 'count 'metric 17)")
    (test-equal "room messages need no effect approval" "()"
      (assq-ref (evaluate "(message-post! 'claude 'codex \"API ready\")") 'proposals))
    (test-equal "room direct data lookup" 17 (value "(saved-ref 'durable)"))
    (test-equal "room direct zone lookup" "ready" (value "(zone-ref 'status)"))
    (evaluate "(effect-propose! 'notify \"pending across restart\")")
    (stop!) (start!)
    (test-equal "isolated state survives restart" 17 (value "durable"))
    (test-equal "room inbox survives restart" '((1 claude "API ready"))
      (value "(message-inbox 'codex)"))
    (test-equal "room reply keeps message cursor" 2
      (value "(message-post! 'codex 'claude \"Tests ready\")"))
    (test-equal "isolated zones preserve order across restart" '((count metric 17) (status text "ready")) (value "(zone-list)"))
    (test-equal "pending request survives restart" 'ok
      (assq-ref (owner 'decide 2 '(notify "pending across restart") 'reject) 'status))
    (test-equal "archive removes decided proposal" 'ok (assq-ref (owner 'archive 1) 'status)))
  stop!)
(for-each (lambda (name) (delete-file (string-append directory "/" name)))
          '("state.scm" "token" "room.sock.lock"))
(rmdir directory)
(test-end "isolated")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
