(define-module (weft runtime)
  #:use-module (ares evaluation eval)
  #:use-module (ice-9 sandbox)
  #:use-module (ice-9 match)
  #:use-module (rnrs io ports)
  #:export (make-room room-evaluate))

(define (bounded-output limit)
  (let ((parts '())
        (size 0)
        (truncated? #f))
    (values (make-custom-textual-output-port "bounded-result"
                                             (lambda (text start count)
                                               (let ((keep (min count
                                                                (- limit size))))
                                                 (when (> keep 0)
                                                   (set! parts
                                                         (cons (substring text
                                                                start
                                                                (+ start keep))
                                                               parts))
                                                   (set! size
                                                         (+ size keep)))
                                                 (when (< keep count)
                                                   (set! truncated? #t)) count))
                                             #f #f #f)
            (lambda ()
              (string-concatenate (reverse parts)))
            (lambda ()
              truncated?))))

(define* (make-room #:key (initialize (lambda (module)
                                        #t)))
  "Create a trusted, process-local Scheme workspace."
  (let* ((name (list 'room
                     (string->symbol (symbol->string (gensym "session-")))))
         (module (resolve-module name))
         (generation (format #f "~a-~a"
                             (getpid)
                             (gettimeofday))))
    (module-use! module
                 (resolve-interface '(guile)))
    (module-define! module
                    'room-state
                    (lambda ()
                      `((generation unquote generation)
                        (persistence . process)
                        (authority . local-user)
                        (sandbox . #f))))
    (module-define! module
                    'room-help
                    (lambda ()
                      '((evaluate . "Definitions survive calls in this process. Exceptions preserve earlier effects; there is no rollback.")
                        (maintenance . "Import application modules and use procedure-documentation for function help.")
                        (discovery . "Use module-map, module-ref and procedure-documentation on imported Guile/Guix modules.")
                        (limits . "Results are bounded; retain large values in variables and return summaries. Evaluation defaults to 30 seconds, at most 50.")
                        (processes . "Subprocess stdout goes to server stderr; capture subprocess output explicitly when needed.")
                        (restart . "A new server process loses definitions and changes the generation. Save reusable code in source modules.")
                        (roadmap . "Shared sessions, browser zones, gated connectors, isolation and durable recovery are not implemented."))))
    (set-module-public-interface! module module)
    (initialize module)
    (cons module generation)))

(define* (room-evaluate room code
                        #:key (seconds 30)
                        (limit 16000))
  "Evaluate CODE in ROOM and return bounded Scheme result and output fields."
  (unless (and (string? code)
               (<= (string-length code) 131072)
               (real? seconds)
               (> seconds 0)
               (<= seconds 50))
    (error "Expected Scheme source up to 128 KiB and timeout in (0, 50]"))
  (call-with-values (lambda ()
                      (bounded-output limit))
                    (lambda (output output-text output-truncated?)
                      (call-with-values (lambda ()
                                          (bounded-output limit))
                                        (lambda (result-port result-text
                                                 result-truncated?)
                                          (let ((status 'ok))
                                            (call-with-time-limit seconds
                                                                  (lambda ()
                                                                    (parameterize
                                                                                  (
                                                                                   (current-output-port
                                                                                    output)


                                                                                   (current-error-port
                                                                                    output)


                                                                                   (current-warning-port
                                                                                    output)


                                                                                   (current-input-port
                                                                                    (open-input-string
                                                                                     "")))
                                                                      (let* ((result
                                                                              (
                                                                               (evaluation-thunk `
                                                                                (
                                                                                 ("code"
                                                                                  unquote
                                                                                  code)


                                                                                 ("ns"
                                                                                  unquote


                                                                                  (object->string
                                                                                   (module-name
                                                                                    (car
                                                                                     room))))))))
                                                                             (kind
                                                                              (assq-ref
                                                                               result
                                                                               'result-type)))
                                                                        (case kind
                                                                          ((value
                                                                            multiple-values)
                                                                           (write
                                                                            (assq-ref
                                                                             result
                                                                             'eval-value)
                                                                            result-port))
                                                                          (else
                                                                           (set!
                                                                            status
                                                                            'error)
                                                                           (write
                                                                            (assq-ref
                                                                             result
                                                                             'exception-value)
                                                                            result-port))))))
                                                                  (lambda ()
                                                                    (set!
                                                                     status
                                                                     'timeout)))
                                            (force-output output)
                                            (force-output result-port)
                                            `((generation unquote
                                                          (cdr room))
                                              (status unquote status)
                                              (value unquote
                                                     (result-text))
                                              (output unquote
                                                      (output-text))
                                              (truncated unquote
                                                         (or (output-truncated?)
                                                             (result-truncated?))))))))))
