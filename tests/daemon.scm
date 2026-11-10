(use-modules (weft daemon) (ice-9 ftw) (rnrs bytevectors) (srfi srfi-64))

(test-begin "daemon")
(define runner (test-runner-current))
(define directory (mkdtemp "/tmp/weft-daemon-XXXXXX"))
(define path (string-append directory "/workspace.sock"))
(define child #f)
(define initial #f)

(define (start!)
  (force-output)
  (set! child (primitive-fork))
  (when (zero? child)
    (catch #t
      (lambda ()
        (serve-workspace path #:initialize
          (lambda (module) (module-define! module 'initialized 42)))
        (primitive-exit 0))
      (lambda args
        (write args (current-error-port))
        (primitive-exit 1))))
  (let loop ((remaining 100))
    (unless (and (file-exists? path)
                 (catch #t (lambda () (remote-evaluate path "#t") #t)
                        (lambda args #f)))
      (when (zero? remaining) (error "Daemon did not start"))
      (usleep 20000)
      (loop (- remaining 1)))))

(define (stop!)
  (when child
    (kill child SIGTERM)
    (let ((status (cdr (waitpid child))))
      (set! child #f)
      status)))

(let* ((module (resolve-module '(weft daemon)))
       (construct (eval '(lambda (port time) (make-client port '() 0 #f 0 time)) module))
       (handle (module-ref module 'handle-client!))
       (touch (eval '(lambda (client time) (set-client-touched! client time)) module))
       (clock (module-ref module 'now))
       (pair (socketpair AF_UNIX SOCK_STREAM 0))
       (workspace ((@ (weft runtime) make-workspace)))
       (client (construct (car pair) (- (clock) 11))))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (send (cdr pair) (string->utf8 "{\"code\":\"1\"}\n"))
      (test-assert "ready input survives time spent waiting for evaluator"
        (handle workspace client (list (car pair)) '()))
      (touch client (- (clock) 11))
      (handle workspace client '() (list (car pair)))
      (test-assert "ready reply survives time spent waiting for evaluator"
        (pair? (car (select (list (cdr pair)) '() '() 0 0)))))
    (lambda ()
      (close-port (car pair)) (close-port (cdr pair))
      ((@ (weft runtime) workspace-close) workspace))))

(dynamic-wind
  (lambda () #t)
  (lambda ()
    (start!)
    (test-equal "socket private" #o600 (stat:perms (stat path)))
    (test-equal "initializer available" "42"
      (assq-ref (remote-evaluate path "initialized") 'value))
    (set! initial (remote-evaluate path "(define shared 9) shared"))
    (test-equal "separate clients share definitions" "10"
      (assq-ref (remote-evaluate path "(+ shared 1)") 'value))
    (test-equal "separate clients retain generation" (assq-ref initial 'generation)
      (assq-ref (remote-evaluate path "shared") 'generation))
    (test-error "live daemon cannot be replaced" #t (serve-workspace path))
    (let ((idle (socket AF_UNIX SOCK_STREAM 0)))
      (dynamic-wind
        (lambda () (connect idle AF_UNIX path))
        (lambda ()
          (send idle (string->utf8 "{\"code\":"))
          (test-equal "partial idle request does not block another client" "9"
            (assq-ref (remote-evaluate path "shared") 'value)))
        (lambda () (close-port idle))))
    (test-equal "deadline still interrupts evaluation" 'timeout
      (assq-ref (remote-evaluate path "(let loop () (loop))" #:seconds 0.05) 'status))
    (test-equal "daemon recovers after deadline" "9"
      (assq-ref (remote-evaluate path "shared") 'value))
    (test-error "invalid explicit deadline is rejected" #t
      (remote-evaluate path "shared" #:seconds #f))
    (remote-evaluate path "(define job (job-start (list \"sleep\" \"30\")))")
    (test-equal "disconnect retains managed job" "running"
      (assq-ref (remote-evaluate path "(assq-ref (job-status (assq-ref job 'id)) 'state)") 'value))
    (remote-evaluate path
      "(define dispatched 0) (define (first e) (event-emit! 'second #f)) (define (second e) (set! dispatched (+ dispatched 1))) (event-on! 'one 'first 'first) (event-on! 'two 'second 'second) (event-emit! 'first #f)")
    (usleep 300000)
    (test-equal "daemon dispatches queued followup while clients are idle" "1"
      (assq-ref (remote-evaluate path "dispatched") 'value))
    (test-equal "clean shutdown" 0 (stop!))
    (test-assert "shutdown removes socket" (not (file-exists? path)))
    (let ((stale (socket AF_UNIX SOCK_STREAM 0)))
      (bind stale AF_UNIX path)
      (close-port stale))
    (start!)
    (test-assert "restart changes generation"
      (not (equal? (assq-ref initial 'generation)
                   (assq-ref (remote-evaluate path "#t") 'generation))))
    (test-equal "restart clears definitions" 'error
      (assq-ref (remote-evaluate path "shared") 'status))
    (stop!))
  (lambda ()
    (when child (stop!))
    (when (file-exists? path) (delete-file path))
    (when (file-exists? (string-append path ".lock"))
      (delete-file (string-append path ".lock")))
    (rmdir directory)))
(test-end "daemon")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
