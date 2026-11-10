(use-modules (weft jobs) (srfi srfi-64) (ice-9 threads))

(test-begin "jobs")
(define manager (make-job-manager))
(define (start . argv) (assq-ref (job-start manager argv) 'id))
(define (field status key) (assq-ref status key))

(test-equal "initially empty" '() (job-list manager))
(test-error "empty argv" #t (job-start manager '()))
(test-error "nonstring argv" #t (job-start manager '("printf" 2)))
(test-error "nul argv" #t (job-start manager (list "printf" (string #\nul))))
(test-error "unknown status" #t (job-status manager 999))
(test-error "unknown cancel" #t (job-cancel manager 999))
(test-error "unknown forget" #t (job-forget manager 999))
(test-error "unknown wait" #t (job-wait manager 999 0))

(define jobs-module (resolve-module '(weft jobs)))
(define (with-binding name value thunk)
  (let ((old (module-ref jobs-module name)))
    (dynamic-wind
      (lambda () (module-define! jobs-module name value))
      thunk
      (lambda ()
        (module-define! jobs-module name old)))))

(define first-pipe #f)
(define real-pipe pipe)
(with-binding 'pipe
  (lambda ()
    (if first-pipe
      (error "injected pipe failure")
      (let ((pair (real-pipe))) (set! first-pipe pair) pair)))
  (lambda ()
    (test-error "pipe setup failure" #t (job-start manager '("sleep" "10")))))
(test-assert "pipe setup failure closes acquired ports"
  (and (port-closed? (car first-pipe)) (port-closed? (cdr first-pipe))))

(define failed-pid #f)
(define real-fork primitive-fork)
(with-binding 'primitive-fork
  (lambda () (let ((pid (real-fork))) (set! failed-pid pid) pid))
  (lambda ()
    (with-binding 'call-with-new-thread
      (lambda args (error "injected thread failure"))
      (lambda ()
        (test-error "thread setup failure" #t
          (job-start manager '("sleep" "10")))))))
(test-error "thread setup failure reaps child" #t (waitpid failed-pid WNOHANG))
(test-equal "failed starts never publish jobs" '() (job-list manager))

(define signalled-before-reap? #f)
(define real-signal-group (module-ref jobs-module 'signal-group))
(define child-pid (eval '(lambda (job) (job-pid job)) jobs-module))
(with-binding 'signal-group
  (lambda (job)
    (set! signalled-before-reap?
      (catch #t
        (lambda ()
          ((module-ref jobs-module 'child-exited?)
            (child-pid job)))
        (lambda args #f)))
    (real-signal-group job))
  (lambda ()
    (let ((id (start "true")))
      (job-wait manager id 2)
      (job-forget manager id))))
(test-assert "group cleanup preserves unreaped leader" signalled-before-reap?)

(define literal (start "printf" "%s" "$(touch /tmp/weft-must-not-exist); *"))
(define literal-result (job-wait manager literal 2))
(test-equal "argv is literal" "$(touch /tmp/weft-must-not-exist); *"
  (field literal-result 'stdout))
(test-equal "successful exit" 0 (field literal-result 'exit-code))
(test-equal "terminal state" 'exited (field literal-result 'state))
(test-assert "forget terminal" (job-forget manager literal))
(test-error "forgotten ID" #t (job-status manager literal))

(define failure (start "sh" "-c" "printf out; printf err >&2; exit 7"))
(define failure-result (job-wait manager failure 2))
(test-equal "separate stdout" "out" (field failure-result 'stdout))
(test-equal "separate stderr" "err" (field failure-result 'stderr))
(test-equal "nonzero exit" 7 (field failure-result 'exit-code))
(test-assert "stable monotonic IDs" (> failure literal))
(define missing (start "/weft/no/such/program"))
(test-equal "exec failure is observable" 127
  (field (job-wait manager missing 2) 'exit-code))

(define long (start "sleep" "10"))
(test-equal "wait timeout preserves running job" 'running
  (field (job-wait manager long 0.02) 'state))
(test-error "cannot forget running job" #t (job-forget manager long))
(test-error "negative wait" #t (job-wait manager long -1))
(test-error "excessive wait" #t (job-wait manager long 11))
(define cancelled (job-cancel manager long))
(test-equal "cancel state" 'cancelled (field cancelled 'state))
(test-equal "cancel signal" SIGKILL (field cancelled 'signal))
(test-equal "cancel idempotent" cancelled (job-cancel manager long))
(test-error "child reaped" #t (waitpid (field cancelled 'pid) WNOHANG))

(define noisy
  (start "sh" "-c"
    "head -c 100000 /dev/zero | tr '\\000' x; printf END; printf '\\377' >&2"))
(define noisy-result (job-wait manager noisy 3))
(test-equal "bounded output" 16384 (string-length (field noisy-result 'stdout)))
(test-assert "output tail retained" (string-suffix? "END" (field noisy-result 'stdout)))
(test-assert "truncation reported" (field noisy-result 'truncated))
(test-equal "binary replacement" "�" (field noisy-result 'stderr))
(define unicode (start "printf" "%s" "日本語 🧵"))
(test-equal "UTF-8 output" "日本語 🧵"
  (field (job-wait manager unicode 2) 'stdout))

(define orphan (start "sh" "-c" "sleep 10 & printf done"))
(test-equal "leader exit closes descendant pipes" 'exited
  (field (job-wait manager orphan 2) 'state))
(define tree (start "sh" "-c" "trap '' TERM; sleep 10 & wait"))
(test-equal "cancel process group despite ignored TERM" SIGKILL
  (field (job-cancel manager tree) 'signal))

(define closing (start "sleep" "10"))
(define closing-pid (field (job-status manager closing) 'pid))
(test-assert "close" (jobs-close manager))
(test-error "closed child reaped" #t (waitpid closing-pid WNOHANG))
(test-equal "close clears jobs" '() (job-list manager))
(test-error "closed manager rejects start" #t (job-start manager '("true")))
(test-assert "close idempotent" (jobs-close manager))
(define runner (test-runner-current))
(test-end "jobs")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
