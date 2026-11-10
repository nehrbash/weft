(define-module (weft jobs)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 iconv)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:export (make-job-manager job-start job-list job-status job-wait
             job-cancel job-forget jobs-close))

(define-record-type <manager>
  (%make-manager next jobs closed?)
  manager?
  (next manager-next set-manager-next!)
  (jobs manager-jobs set-manager-jobs!)
  (closed? manager-closed? set-manager-closed!))

(define-record-type <job>
  (make-job id argv pid mutex state out err truncated? reaped? status thread)
  job?
  (id job-id)
  (argv job-argv)
  (pid job-pid)
  (mutex job-mutex)
  (state job-state set-job-state!)
  (out job-out set-job-out!)
  (err job-err set-job-err!)
  (truncated? job-truncated? set-job-truncated!)
  (reaped? job-reaped? set-job-reaped!)
  (status job-exit-status set-job-exit-status!)
  (thread job-thread set-job-thread!))

(define (make-job-manager)
  "Create process-local subprocess storage; call jobs-close before exit."
  (%make-manager 1 '() #f))

(define output-limit 16384)

;; Linux siginfo_t is 128 bytes; si_signo is its first int on all Linux ABIs.
(define waitid
  (and (string-contains %host-type "linux")
    (pointer->procedure int (dynamic-func "waitid" (dynamic-link))
      (list int int '* int) #:return-errno? #t)))

(define (child-exited? pid)
  (unless waitid (error "Subprocess jobs require GNU/Linux"))
  (let ((info (make-bytevector 128 0)))
    (call-with-values
      ;; P_PID, WEXITED | WNOHANG | WNOWAIT preserve group ownership until kill.
      (lambda () (waitid 1 pid (bytevector->pointer info) #x1000005))
      (lambda (result errno)
        (cond ((zero? result) (not (zero? (bytevector-s32-native-ref info 0))))
          ((= errno EINTR) #f)
          (else (error "waitid failed" errno)))))))

(define (lookup manager id)
  (or (and (exact-integer? id) (assv-ref (manager-jobs manager) id))
    (error "Unknown job ID" id)))

(define (signal-group job)
  (catch 'system-error
    (lambda () (kill (- (job-pid job)) SIGKILL))
    (lambda args
      (unless (= ESRCH (system-error-errno args)) (apply throw args)))))

(define (append-output! job bytes stderr?)
  (with-mutex (job-mutex job)
    (let* ((old ((if stderr? job-err job-out) job))
            (size (+ (bytevector-length old) (bytevector-length bytes)))
            (keep (min output-limit size))
            (tail (make-bytevector keep))
            (skip (- size keep))
            (old-start (min skip (bytevector-length old)))
            (old-count (- (bytevector-length old) old-start))
            (new-start (- skip old-start)))
      (bytevector-copy! old old-start tail 0 old-count)
      (bytevector-copy! bytes new-start tail old-count (- keep old-count))
      ((if stderr? set-job-err! set-job-out!) job tail)
      (when (> size output-limit) (set-job-truncated! job #t)))))

(define (drain-job job stdout stderr)
  ;; Only subprocess I/O runs here: workspace evaluation owns SIGALRM.
  (let loop ((ports (list stdout stderr)) (status #f) (drain-deadline #f))
    (let* ((reaped (and (not status)
                     (with-mutex (job-mutex job)
                       (if (child-exited? (job-pid job))
                         (begin
                           (signal-group job)
                           (let ((result (waitpid (job-pid job))))
                             (set-job-reaped! job #t)
                             result))
                         #f))))
            (finished (or status (and reaped (> (car reaped) 0) (cdr reaped))))
            (deadline (or drain-deadline
                        (and finished (+ (get-internal-real-time)
                                        internal-time-units-per-second)))))
      ;; A descendant can deliberately escape its group while retaining a pipe.
      (if (and finished (or (null? ports)
                          (>= (get-internal-real-time) deadline)))
        (with-mutex (job-mutex job)
          (set-job-exit-status! job finished)
          (unless (eq? (job-state job) 'cancelled)
            (set-job-state! job 'exited)))
        (let* ((ready (if (null? ports)
                        (begin (usleep 10000) '())
                        (car (select ports '() '() 0 10000))))
                (remaining
                  (fold (lambda (port rest)
                          (let ((bytes (get-bytevector-some port)))
                            (if (eof-object? bytes)
                              (begin (close-port port) (delq port rest))
                              (begin
                                (append-output! job bytes (eq? port stderr))
                                rest))))
                    ports ready)))
          (loop remaining finished deadline))))))

(define (supervise job stdout stderr)
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (catch #t
        (lambda () (drain-job job stdout stderr))
        (lambda args
          (let ((status
                 (with-mutex (job-mutex job)
                   (unless (job-reaped? job) (signal-group job))
                   (let ((result
                          (catch 'system-error
                            (lambda () (cdr (waitpid (job-pid job))))
                            (lambda args
                              (if (= ECHILD (system-error-errno args))
                                  (* 127 256)
                                  (apply throw args))))))
                     (set-job-reaped! job #t)
                     result))))
            (append-output! job
              (string->utf8 "\nJob output collection failed.\n") #t)
            (with-mutex (job-mutex job)
              (set-job-exit-status! job status)
              (unless (eq? (job-state job) 'cancelled)
                (set-job-state! job 'exited)))))))
    (lambda ()
      (for-each (lambda (port)
                  (unless (port-closed? port) (close-port port)))
        (list stdout stderr)))))

(define (job-start manager argv)
  "Start an explicit argv with null stdin and bounded UTF-8 output tails."
  (unless waitid (error "Subprocess jobs require GNU/Linux"))
  (when (manager-closed? manager) (error "Job manager is closed"))
  (unless (and (list? argv) (pair? argv) (every string? argv)
            (every (lambda (arg) (not (string-index arg #\nul))) argv)
            (not (string-null? (car argv)))
            (<= (length argv) 256)
            (<= (apply + (map string-length argv)) 65536))
    (error "Expected nonempty argv of at most 256 strings and 64 KiB"))
  (when (>= (length (manager-jobs manager)) 128)
    (error "Job limit reached; forget terminal jobs"))
  (call-with-blocked-asyncs
    (lambda ()
      (let ((ports '()) (pid #f) (owned-group? #f) (job #f) (committed? #f))
        (define (new-pipe)
          (let ((pair (pipe)))
            (set! ports (cons* (car pair) (cdr pair) ports))
            pair))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (let* ((stdout (new-pipe))
                    (stderr (new-pipe)))
              (for-each (lambda (port)
                          (fcntl port F_SETFD FD_CLOEXEC)
                          (setvbuf port 'none)) ports)
              (set! pid (primitive-fork))
              (if (= pid 0)
                (catch #t
                  (lambda ()
                    (setpgid 0 0)
                    (let ((input (open-input-file "/dev/null")))
                      (dup2 (fileno input) 0))
                    (dup2 (fileno (cdr stdout)) 1)
                    (dup2 (fileno (cdr stderr)) 2)
                    (for-each close-port ports)
                    (apply execlp (car argv) argv))
                  (lambda args (primitive-exit 127)))
                (begin
                  (close-port (cdr stdout))
                  (close-port (cdr stderr))
                  (catch 'system-error
                    (lambda () (setpgid pid pid))
                    (lambda args
                      (unless (memv (system-error-errno args) (list EACCES ESRCH))
                        (apply throw args))))
                  (set! owned-group? #t)
                  (let* ((id (manager-next manager))
                          (new-job (make-job id (map string-copy argv) pid (make-mutex)
                                     'running (make-bytevector 0)
                                     (make-bytevector 0) #f #f #f #f)))
                    (set! job new-job)
                    (set-job-thread! job
                      (call-with-new-thread
                        (lambda ()
                          (supervise job (car stdout) (car stderr)))))
                    (set-manager-next! manager (+ id 1))
                    (set-manager-jobs! manager (acons id job (manager-jobs manager)))
                    (set! committed? #t)
                    (job-status manager id))))))
          (lambda ()
            (unless committed?
              (when (and pid (> pid 0))
                (if (and job (job-thread job))
                  (begin
                    (with-mutex (job-mutex job)
                      (unless (job-reaped? job) (signal-group job)))
                    (join-thread (job-thread job)))
                  (begin
                    (catch 'system-error
                      (lambda () (kill (if owned-group? (- pid) pid) SIGKILL))
                      (lambda args
                        (unless (= ESRCH (system-error-errno args))
                          (apply throw args))))
                    (waitpid pid))))
              (for-each (lambda (port)
                          (unless (port-closed? port) (close-port port))) ports))))))))

(define (job-status manager id)
  "Return a bounded snapshot; invalid UTF-8 bytes use replacement characters."
  (let ((job (lookup manager id)))
    (with-mutex (job-mutex job)
      (let ((status (job-exit-status job)))
        `((id . ,id)
           (state . ,(job-state job))
           (pid . ,(job-pid job))
           (stdout . ,(bytevector->string (job-out job) "UTF-8" 'substitute))
           (stderr . ,(bytevector->string (job-err job) "UTF-8" 'substitute))
           (truncated . ,(job-truncated? job))
           (exit-code . ,(and status (status:exit-val status)))
           (signal . ,(and status (status:term-sig status))))))))

(define (job-list manager)
  "Return snapshots in creation order (at most 128 jobs)."
  (map (lambda (entry) (job-status manager (car entry)))
    (reverse (manager-jobs manager))))

(define* (job-wait manager id #:optional (seconds 1))
  "Wait at most SECONDS (0 through 10); a timeout leaves the job running."
  (unless (and (real? seconds) (<= 0 seconds 10))
    (error "Wait seconds must be between 0 and 10"))
  (let* ((job (lookup manager id))
          (deadline (+ (get-internal-real-time)
                      (* seconds internal-time-units-per-second))))
    (let loop ()
      (if (or (job-exit-status job)
            (>= (get-internal-real-time) deadline))
        (job-status manager id)
        (begin (usleep 10000) (loop))))))

(define (job-cancel manager id)
  "Kill the owned process group and return its reaped status."
  (let ((job (lookup manager id)))
    (with-mutex (job-mutex job)
      (unless (job-reaped? job)
        (signal-group job)
        (set-job-state! job 'cancelled)))
    (job-wait manager id 1)))

(define (job-forget manager id)
  "Remove a reaped job; running jobs must be cancelled or awaited first."
  (let ((job (lookup manager id)))
    (unless (job-exit-status job) (error "Cannot forget a running job" id))
    (join-thread (job-thread job))
    (set-manager-jobs! manager (alist-delete id (manager-jobs manager) eqv?))
    #t))

(define (jobs-close manager)
  "Cancel subprocess groups and reap them before releasing the manager."
  (set-manager-closed! manager #t)
  (for-each (lambda (entry) (job-cancel manager (car entry)))
    (manager-jobs manager))
  (for-each (lambda (entry) (join-thread (job-thread (cdr entry))))
    (manager-jobs manager))
  (set-manager-jobs! manager '())
  #t)
