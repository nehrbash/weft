(use-modules (ice-9 popen)
             (ice-9 rdelim)
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
            (assq-ref (evaluate "(room-help)")
                      'status))
(test-equal "runtime identity is discoverable"
            'ok
            (assq-ref (evaluate "(room-state)")
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
(test-end "weft")
(close-pipe server)
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
