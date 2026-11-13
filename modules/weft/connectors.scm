(define-module (weft connectors)
  #:use-module (weft jobs)
  #:use-module (ice-9 match)
  #:export (execute-effect))

(define (run argv cwd)
  (let* ((manager (make-job-manager))
         (id (assq-ref (job-start manager argv #:cwd cwd) 'id)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let loop ((remaining 3))
          (let ((status (job-wait manager id 10)))
            (cond
             ((and (eq? 'exited (assq-ref status 'state))
                   (equal? 0 (assq-ref status 'exit-code))) status)
             ((or (assq-ref status 'exit-code) (assq-ref status 'signal))
              (error "Connector failed" status))
             ((zero? remaining) (error "Connector exceeded 40 seconds"))
             (else (loop (- remaining 1)))))))
      (lambda () (jobs-close manager)))))

(define (execute-effect type payload)
  "Execute one owner-approved effect with literal argument boundaries."
  (case type
    ((notify)
     (run (list "notify-send" "--app-name=Weft" "--expire-time=15000" "--"
                "Weft" payload) #f))
    ((run) (match payload ((cwd argv) (run argv cwd))))
    ((write-file)
     (match payload
       ((path text)
        (let ((port (fdopen (open-fdes path (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW) #o600) "w")))
          (dynamic-wind
            (lambda () #t)
            (lambda () (display text port) (force-output port) (fsync port))
            (lambda () (close-port port)))
          `((path . ,path) (characters . ,(string-length text)))))))
    ((session-send)
     (match payload
       ((session prompt)
        (if (string-prefix? "codex:" session)
            (run (list "weft" "codex-send" (substring session 6) prompt) #f)
            (run (list "emacsclient" "--eval"
                       (format #f "(weft-session-send ~s ~s)" session prompt)) #f)))))
    (else (error "Unknown connector" type))))
