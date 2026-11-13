(define-module (weft daemon)
  #:use-module (weft runtime)
  #:use-module (json)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (serve-workspace remote-evaluate))

(define request-limit 1048576)
(define client-limit 32)

(define-record-type <client>
  (make-client port chunks size reply offset touched)
  client?
  (port client-port)
  (chunks client-chunks set-client-chunks!)
  (size client-size set-client-size!)
  (reply client-reply set-client-reply!)
  (offset client-offset set-client-offset!)
  (touched client-touched set-client-touched!))

(define (now) (/ (get-internal-real-time) internal-time-units-per-second))

(define (nonblocking! port)
  (fcntl port F_SETFD FD_CLOEXEC)
  (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL))))

(define (would-block? args)
  (memv (system-error-errno args) (list EAGAIN EWOULDBLOCK EINTR)))

(define (bytes-append chunks)
  (let* ((size (apply + (map bytevector-length chunks)))
         (result (make-bytevector size)))
    (let loop ((chunks chunks) (offset 0))
      (unless (null? chunks)
        (let ((count (bytevector-length (car chunks))))
          (bytevector-copy! (car chunks) 0 result offset count)
          (loop (cdr chunks) (+ offset count)))))
    result))

(define (slice bytes start end)
  (let ((result (make-bytevector (- end start))))
    (bytevector-copy! bytes start result 0 (- end start))
    result))

(define (line-end bytes count)
  (let loop ((i 0))
    (cond ((= i count) #f)
          ((= 10 (bytevector-u8-ref bytes i)) i)
          (else (loop (+ i 1))))))

(define (reply-bytes result)
  (string->utf8 (string-append (scm->json-string result) "\n")))

(define (evaluate-request workspace bytes)
  (catch #t
    (lambda ()
      (let* ((request (json-string->scm (utf8->string bytes)))
             (code (assoc-ref request "code"))
             (seconds (if (assoc "seconds" request)
                          (assoc-ref request "seconds") 30)))
        (let* ((result (if (procedure? workspace) (workspace code seconds)
                           (workspace-evaluate workspace code #:seconds seconds)))
               (status (assq-ref result 'status)))
          (unless (procedure? workspace) (workspace-tick! workspace))
          (reply-bytes `((result . ,(acons 'status (symbol->string status)
                                          (alist-delete 'status result eq?))))))))
    (lambda args
      (reply-bytes '((error . "Invalid evaluation request"))))))

(define (receive-client! workspace client)
  (let* ((bytes (make-bytevector 4096))
         (count (recv! (client-port client) bytes)))
    (if (zero? count)
        #f
        (let* ((end (line-end bytes count))
               (part (slice bytes 0 (or end count)))
               (size (+ (client-size client) (bytevector-length part))))
          (set-client-touched! client (now))
          (if (> size request-limit)
              #f
              (begin
                (set-client-size! client size)
                (set-client-chunks! client (cons part (client-chunks client)))
                (when end
                  (set-client-reply! client
                    (evaluate-request workspace
                      (bytes-append (reverse (client-chunks client)))))
                  (set-client-chunks! client '())
                  (set-client-touched! client (now)))
                #t))))))

(define (send-client! client)
  (let* ((bytes (client-reply client))
         (start (client-offset client))
         (end (min (+ start 4096) (bytevector-length bytes)))
         ;; MSG_NOSIGNAL keeps a disconnected client from terminating the daemon.
         (sent (send (client-port client) (slice bytes start end) #x4000)))
    (set-client-offset! client (+ start sent))
    (set-client-touched! client (now))
    (< (client-offset client) (bytevector-length bytes))))

(define (handle-client! workspace client readable writable)
  (catch 'system-error
    (lambda ()
      (cond ((and (client-reply client) (memq (client-port client) writable))
             (send-client! client))
            ((and (not (client-reply client)) (memq (client-port client) readable))
             (receive-client! workspace client))
            ((> (- (now) (client-touched client)) 10) #f)
            (else #t)))
    (lambda args (and (would-block? args) #t))))

(define (prepare-directory! path)
  (let ((directory (dirname path)))
    (unless (file-exists? directory) (mkdir directory #o700))
    (let ((info (lstat directory)))
      (unless (and (eq? (stat:type info) 'directory)
                   (= (stat:uid info) (getuid))
                   (zero? (logand (stat:perms info) #o077)))
        (error "Socket directory must be owned by this user with mode 0700" directory)))))

(define (remove-stale-socket! path)
  (when (file-exists? path)
    (let ((info (lstat path)))
      (unless (and (eq? (stat:type info) 'socket) (= (stat:uid info) (getuid)))
        (error "Refusing to replace non-owned socket path" path)))
    (let ((probe (socket AF_UNIX SOCK_STREAM 0)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (nonblocking! probe)
          (catch 'system-error
            (lambda ()
              (connect probe AF_UNIX path)
              (error "Workspace daemon is already running" path))
            (lambda args
              (if (memv (system-error-errno args) (list ECONNREFUSED ENOENT))
                  (when (file-exists? path) (delete-file path))
                  (apply throw args)))))
        (lambda () (close-port probe))))))

(define* (serve-workspace path #:key (initialize (lambda (module) #t)) state-file isolated?
                          external-persistence? evaluator (finalize (lambda () #t)))
  "Serve one persistent workspace over a private GNU/Linux Unix socket."
  (prepare-directory! path)
  (let ((lock (fdopen (open-fdes (string-append path ".lock")
                                  (logior O_WRONLY O_CREAT O_NOFOLLOW) #o600) "w"))
        (listener #f) (workspace #f) (clients '()) (bound? #f)
        (stopping? #f) (handlers '()))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (chmod lock #o600)
        (fcntl lock F_SETFD FD_CLOEXEC)
        (flock lock (logior LOCK_EX LOCK_NB))
        (remove-stale-socket! path)
        (set! workspace (or evaluator
                           (make-workspace #:initialize initialize #:state-file state-file
                                           #:isolated? isolated?
                                           #:external-persistence? external-persistence?)))
        (set! listener (socket AF_UNIX SOCK_STREAM 0))
        (nonblocking! listener)
        (bind listener AF_UNIX path)
        (set! bound? #t)
        (chmod path #o600)
        (listen listener 16)
        (for-each
          (lambda (signal)
            (set! handlers
              (acons signal (sigaction signal (lambda (_) (set! stopping? #t))) handlers)))
          (list SIGTERM SIGINT))
        (let loop ()
          (unless stopping?
            (let* ((reading (filter (lambda (c) (not (client-reply c))) clients))
                   (writing (filter client-reply clients))
                   (ready (catch 'system-error
                            (lambda ()
                              (select (cons listener (map client-port reading))
                                      (map client-port writing) '() 0 100000))
                            (lambda args
                              (if (would-block? args) (list '() '() '())
                                  (apply throw args)))))
                   (readable (car ready)) (writable (cadr ready)))
              (when (memq listener readable)
                (let ((port (car (accept listener))))
                  (nonblocking! port)
                  (if (< (length clients) client-limit)
                      (set! clients (cons (make-client port '() 0 #f 0 (now)) clients))
                      (close-port port))))
              (set! clients
                (filter (lambda (client)
                          (if (handle-client! workspace client readable writable)
                              #t
                              (begin (close-port (client-port client)) #f))) clients))
              (unless (procedure? workspace) (workspace-tick! workspace))
              (loop)))))
      (lambda ()
        (for-each (lambda (entry)
                    (sigaction (car entry) (car (cdr entry)) (cdr (cdr entry)))) handlers)
        (for-each (lambda (client) (close-port (client-port client))) clients)
        (when listener (close-port listener))
        (when bound? (delete-file path))
        (when (and workspace (not (procedure? workspace))) (workspace-close workspace))
        (finalize)
        (close-port lock)))))

(define* (remote-evaluate path code #:key (seconds 30))
  "Evaluate in a shared workspace; disconnecting retains its state and jobs."
  (let* ((port (socket AF_UNIX SOCK_STREAM 0))
         (bytes (reply-bytes `((code . ,code) (seconds . ,seconds))))
         (deadline (+ (now) 65)))
    (define (wait-ready reading? )
      (let ((remaining (- deadline (now))))
        (unless (and (> remaining 0)
                     (pair? (list-ref
                              (select (if reading? (list port) '())
                                      (if reading? '() (list port)) '()
                                      (inexact->exact (ceiling remaining)))
                              (if reading? 0 1))))
          (error "Workspace request timed out; its evaluation may still complete"))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (nonblocking! port)
        (connect port AF_UNIX path)
        (let loop ((offset 0))
          (when (< offset (bytevector-length bytes))
            (wait-ready #f)
            (let ((sent (send port (slice bytes offset
                                    (min (+ offset 4096) (bytevector-length bytes))) #x4000)))
              (loop (+ offset sent)))))
        (let loop ((chunks '()) (size 0))
          (wait-ready #t)
          (let* ((part (make-bytevector 4096)) (count (recv! port part))
                 (end (line-end part count))
                 (total (+ size (or end count))))
            (when (zero? count) (error "Workspace closed without a response"))
            (when (> total request-limit) (error "Oversized workspace response"))
            (let ((chunks (cons (slice part 0 (or end count)) chunks)))
              (if end
                  (let* ((reply (json-string->scm
                                 (utf8->string (bytes-append (reverse chunks)))))
                         (result (assoc-ref reply "result")))
                    (if result
                        (map (lambda (key)
                               (let ((value (assoc-ref result (symbol->string key))))
                                 (cons key (if (eq? key 'status)
                                               (string->symbol value) value))))
                             (filter (lambda (key) (assoc (symbol->string key) result))
                                     '(generation status value output truncated saved zones advice effects proposals)))
                        (error (assoc-ref reply "error"))))
                  (loop chunks total))))))
      (lambda () (close-port port)))))
