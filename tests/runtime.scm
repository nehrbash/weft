(use-modules (weft runtime)
             (srfi srfi-64))

(test-begin "runtime")
(define runner (test-runner-current))
(define workspace
  (make-workspace
   #:initialize (lambda (module)
                  (module-define! module 'application-value 42))))

(define (evaluate code . timeout)
  (workspace-evaluate workspace code
                      #:seconds (if (null? timeout) 30 (car timeout))))

(define (value code)
  (call-with-input-string (assq-ref (evaluate code) 'value) read))

(test-equal "initializer populates evaluation module" 42
            (value "application-value"))
(test-equal "state binding matches host API"
            (workspace-state workspace)
            (value "(workspace-state)"))
(test-equal "help binding matches host API"
            (workspace-help workspace)
            (value "(workspace-help)"))
(test-assert "room procedures are quiet aliases"
  (and (eq? make-room make-workspace)
       (eq? room-evaluate workspace-evaluate)
       (eq? room-help workspace-help)
       (eq? room-state workspace-state)
       (value "(and (eq? room-help workspace-help) (eq? room-state workspace-state))")))
(test-equal "legacy evaluator accepts canonical workspace" "42"
            (assq-ref (room-evaluate workspace "application-value") 'value))
(test-assert "all job bindings are callable"
  (value "(not (memq #f (map procedure? (list job-start job-list job-status job-wait job-cancel job-forget))))"))
(test-equal "workspace starts with no jobs" '() (value "(job-list)"))
(test-equal "definitions persist" 8
            (begin (evaluate "(define saved 8)") (value "saved")))
(test-equal "error returns error status" 'error
            (assq-ref (evaluate "(error \"fixture\")") 'status))
(test-equal "evaluation recovers after error" 8 (value "saved"))
(test-equal "timeout returns timeout status" 'timeout
            (assq-ref (evaluate "(let loop () (loop))" 0.05) 'status))
(test-equal "evaluation recovers after timeout" 8 (value "saved"))
(test-equal "earlier effects survive error" 9
            (begin (evaluate "(set! saved 9) (error \"fixture\")")
                   (value "saved")))
(test-equal "bounded stdout preserved" "hello"
            (assq-ref (evaluate "(display \"hello\")") 'output))
(define bounded
  (workspace-evaluate workspace
                      "(display (make-string 100 #\\x)) (make-string 100 #\\y)"
                      #:limit 12))
(test-assert "output and result independently bounded"
  (and (assq-ref bounded 'truncated)
       (= 12 (string-length (assq-ref bounded 'output)))
       (= 12 (string-length (assq-ref bounded 'value)))))
(test-equal "job bindings capture the workspace manager" "runtime-job"
  (begin
    (evaluate "(define launched (job-start (list \"printf\" \"runtime-job\")))")
    (value "(assq-ref (job-wait (assq-ref launched (quote id)) 2) (quote stdout))")))
(test-equal "job status is retained across evaluations" (quote exited)
  (value "(assq-ref (job-status (assq-ref launched (quote id))) (quote state))"))
(test-assert "completed job can be forgotten"
  (value "(job-forget (assq-ref launched (quote id)))"))
(define other (make-room))
(test-equal "legacy constructor creates isolated workspace" 'error
            (assq-ref (room-evaluate other "saved") 'status))
(test-assert "initialization errors propagate"
  (catch 'fixture
    (lambda ()
      (make-workspace #:initialize (lambda (module) (throw 'fixture)))
      #f)
    (lambda _ #t)))
(workspace-close other)
(workspace-close workspace)
(workspace-close workspace)
(test-end "runtime")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
