(define-module (weft cli)
  #:use-module (weft mcp)
  #:use-module (weft daemon)
  #:use-module (ice-9 match)
  #:export (main default-socket-path))

(define (default-socket-path)
  "Return this user's local workspace socket path."
  (string-append (if (getenv "XDG_RUNTIME_DIR")
                     (string-append (getenv "XDG_RUNTIME_DIR") "/weft")
                     (string-append "/tmp/weft-" (number->string (getuid))))
                 "/workspace.sock"))

(define* (main args #:key (initialize (lambda (module) #t)))
  "Run standalone MCP, a shared daemon, a bridge, or one Scheme evaluation."
  (define (connect path)
    (serve-stdio #:evaluate
                 (lambda (code seconds)
                   (remote-evaluate path code #:seconds seconds))))
  (define (evaluate path code)
    (let ((result (remote-evaluate path code)))
      (write result)
      (newline)
      (if (eq? 'ok (assq-ref result 'status)) 0 1)))
  (match args
    (() (serve-stdio #:initialize initialize) 0)
    (("standalone") (serve-stdio #:initialize initialize) 0)
    (("daemon") (serve-workspace (default-socket-path) #:initialize initialize) 0)
    (("daemon" path) (serve-workspace path #:initialize initialize) 0)
    (("connect") (connect (default-socket-path)) 0)
    (("connect" path) (connect path) 0)
    (("eval" code) (evaluate (default-socket-path) code))
    (("eval" path code) (evaluate path code))
    (_ (display "Usage: weft [standalone | daemon [SOCKET] | connect [SOCKET] | eval [SOCKET] CODE]\n"
                (current-error-port))
       2)))
