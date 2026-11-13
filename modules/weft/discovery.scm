(define-module (weft discovery)
  #:use-module (weft sessions)
  #:use-module (weft transcripts)
  #:use-module (json)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-session-inspector session-list session-ref session-changes
            install-session-bindings!))

(define-record-type <session>
  (make-session id provider source path attributes)
  session?
  (id session-id) (provider session-provider) (source session-source)
  (path session-path) (attributes session-attributes))

(define-record-type <provider>
  (make-provider name scan lookup)
  provider?
  (name provider-name) (scan provider-scan) (lookup provider-lookup))

(define-record-type <inspector>
  (%make-inspector providers transcripts generation sequence snapshots)
  inspector?
  (providers inspector-providers) (transcripts inspector-transcripts)
  (generation inspector-generation)
  (sequence inspector-sequence set-inspector-sequence!)
  (snapshots inspector-snapshots set-inspector-snapshots!))

(define %diagnostics (make-parameter #f))
(define %fields '(id provider source pid name cwd status updated-at note
                    request reply request-at reply-at turn association transcript))
(define %overview '(id provider status name cwd request))
(define %detail '(id provider source status cwd request reply request-at reply-at association transcript))
(define %activity '(request reply request-at reply-at turn association transcript))

(define (diagnose provider operation target kind message)
  (let ((sink (%diagnostics)))
    (when sink (sink `((provider . ,provider) (operation . ,operation)
                      (target . ,target) (kind . ,kind) (message . ,message))))))

(define* (guarded provider operation target thunk #:key missing-ok?)
  (catch #t thunk
    (lambda (key . args)
      (cond ((memq key '(quit interrupt limit-exceeded timeout)) (apply throw key args))
            ((and missing-ok? (eq? key 'system-error)
                  (= ENOENT (system-error-errno (cons key args)))) #f)
            (else
             (diagnose provider operation target key
               (let ((text (call-with-output-string
                             (lambda (port) (print-exception port #f key args)))))
                 (substring text 0 (min 240 (string-length text)))))
             #f)))))

(define (field object key)
  (let ((value (and (list? object) (assoc-ref object key))))
    (if (eq? value 'null) #f value)))

(define (required object key predicate)
  (let ((value (field object key)))
    (unless (predicate value) (error "Invalid provider field" key)) value))

(define (entries directory)
  (scandir directory (lambda (name) (not (member name '("." ".."))))))

(define (read-json path)
  (call-with-input-file path
    (lambda (port)
      (when (> (stat:size (stat port)) 65536) (error "Registry record exceeds 64 KiB"))
      (json->scm port))))

(define (process-start proc pid)
  (let* ((text (call-with-input-file (format #f "~a/~a/stat" proc pid) read-line))
         (fields (string-tokenize (substring text (+ 2 (string-rindex text #\)))))))
    (list-ref fields 19)))

(define (claude-provider home proc)
  (let ((index (make-hash-table)) (directory (string-append home "/sessions")))
    (define (read-session path)
      (guarded 'claude 'registry path
        (lambda ()
          (let* ((data (read-json path))
                 (pid (required data "pid" integer?))
                 (id (required data "sessionId" string?))
                 (cwd (required data "cwd" string?))
                 (start (guarded 'claude 'process id
                          (lambda () (process-start proc pid)) #:missing-ok? #t)))
            (and start (equal? start (required data "procStart" string?))
                 (begin
                   (hash-set! index id path)
                   (make-session (string-append "claude:" id) 'claude 'claude-registry
                     (string-append home "/projects/"
                       (string-map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) c #\-)) cwd)
                       "/" id ".jsonl")
                     `((pid . ,pid) (name . ,(field data "name")) (cwd . ,cwd)
                       (status . ,(string->symbol (or (field data "status") "unknown")))
                       (updated-at . ,(let ((at (field data "updatedAt")))
                                        (and (number? at) (quotient at 1000))))))))))
        #:missing-ok? #t))
    (define (scan)
      (filter-map (lambda (name) (and (string-suffix? ".json" name)
                                      (read-session (string-append directory "/" name))))
                  (entries directory)))
    (make-provider 'claude scan
      (lambda (id)
        (let ((path (hash-ref index id)))
          (or (and path (let ((row (read-session path)))
                          (and row (equal? (session-id row) (string-append "claude:" id)) row)))
              (find (lambda (row) (equal? (session-id row) (string-append "claude:" id))) (scan))))))))

(define (codex-provider connect)
  (define (read-thread rpc id)
    (guarded 'codex 'thread-read id
      (lambda ()
        (let* ((data (required (rpc "thread/read" `((threadId . ,id))) "thread" list?))
               (status (required (field data "status") "type" string?)))
          (make-session (string-append "codex:" id) 'codex 'codex-app-server (field data "path")
            `((name . ,(field data "name")) (cwd . ,(field data "cwd"))
              (status . ,(string->symbol status)) (updated-at . ,(field data "updatedAt"))))))))
  (make-provider 'codex
    (lambda ()
      (connect (lambda (rpc)
        (let loop ((cursor #f) (seen '()) (rows '()))
          (let ((page (guarded 'codex 'thread-list cursor
                       (lambda ()
                         (let ((page (rpc "thread/loaded/list"
                                      `((limit . 100) ,@(if cursor `((cursor . ,cursor)) '())))))
                           (required page "data" vector?)
                           page)))))
            (if (not page) rows
                (let* ((ids (required page "data" vector?))
                       (next (field page "nextCursor"))
                       (current (filter-map (lambda (id) (read-thread rpc id)) (vector->list ids)))
                       (result (append rows current)))
                  (cond ((not next) result)
                        ((member next seen)
                         (diagnose 'codex 'thread-list next 'pagination "Repeated provider cursor.") result)
                        (else (loop next (cons next seen) result))))))))))
    (lambda (id) (connect (lambda (rpc) (read-thread rpc id))))))

(define (process-provider proc)
  (define (lookup id)
    (guarded 'process 'inspect id
      (lambda ()
        (let ((directory (string-append proc "/" id)))
          (and (= (stat:uid (stat directory)) (getuid))
               (string=? (basename (readlink (string-append directory "/exe"))) "codex")
               (let ((argv (string-split
                       (call-with-input-file (string-append directory "/cmdline") get-string-all) #\nul)))
                 (and (not (member "app-server" argv))
                   (make-session (string-append "process:" id) 'process 'process #f
                     `((pid . ,(string->number id)) (cwd . ,(readlink (string-append directory "/cwd")))
                       (status . unknown) (note . "Alive Codex process; session identity unresolved, may overlap a loaded thread."))))))))
      #:missing-ok? #t))
  (make-provider 'process
    (lambda () (filter-map lookup (filter string->number (entries proc)))) lookup))

(define* (make-session-inspector #:key
          (claude-home (or (getenv "CLAUDE_CONFIG_DIR") (string-append (getenv "HOME") "/.claude")))
          (proc "/proc") (connect call-with-codex))
  "Own provider adapters, transcript caches and bounded change history."
  (%make-inspector (list (claude-provider claude-home proc) (codex-provider connect) (process-provider proc))
    (make-transcript-cache) (format #f "~a-~a-~a" (getpid) (gettimeofday) (gensym)) 0 '()))

(define %default-inspector (delay (make-session-inspector)))

(define (validate-query inspector provider status fields)
  (unless (and (or (not provider) (memq provider (map provider-name (inspector-providers inspector))))
               (or (not status) (symbol? status)) (list? fields)
               (every (lambda (name) (memq name %fields)) fields))
    (error "Expected provider claude/codex/process, symbolic status, and known fields" %fields)))

(define (collect thunk)
  (let ((warnings '()))
    (parameterize ((%diagnostics (lambda (item) (set! warnings (cons item warnings)))))
      (let ((value (thunk))) (values value (reverse (delete-duplicates warnings)))))))

(define (project fields row)
  (map (lambda (name) (cons name (assq-ref row name))) fields))

(define (describe inspector session fields)
  (let* ((id (session-id session)) (provider (session-provider session))
         (activity (and (any (lambda (field) (memq field %activity)) fields)
                        (or (guarded provider 'transcript id
                              (lambda () (transcript-read (inspector-transcripts inspector) (session-path session)
                                (lambda (kind message) (diagnose provider 'transcript id kind message)))))
                            '((transcript . unavailable)))))
         (row (append `((id . ,id) (provider . ,provider) (source . ,(session-source session)))
                      (session-attributes session) (or activity '()))))
    row))

(define (scan inspector provider status fields)
  (append-map (lambda (adapter)
    (if (and provider (not (eq? provider (provider-name adapter)))) '()
        (filter-map (lambda (session)
          (and (or (not status) (eq? status (assq-ref (session-attributes session) 'status)))
               (describe inspector session fields)))
          (or (guarded (provider-name adapter) 'discover #f (provider-scan adapter)) '()))))
    (inspector-providers inspector)))

(define* (session-list #:key provider status (fields %overview) (inspector (force %default-inspector)))
  "Return selected session fields and diagnostics without starting turns."
  (validate-query inspector provider status fields)
  (call-with-values (lambda () (collect (lambda () (scan inspector provider status fields))))
    (lambda (rows warnings) `((sessions . ,(map (lambda (row) (project fields row)) rows)) (warnings . ,warnings)))))

(define* (session-ref id #:key (fields %detail) (inspector (force %default-inspector)))
  "Look up one native ID; return session or #f plus diagnostics."
  (validate-query inspector #f #f fields)
  (match (and (string? id) (string-split id #\:))
    ((provider native-id)
     (let ((adapter (find (lambda (p) (string=? provider (symbol->string (provider-name p))))
                          (inspector-providers inspector))))
       (unless (and adapter (not (string-null? native-id))) (error "Unknown session ID" id))
       (call-with-values
         (lambda () (collect (lambda ()
           (let ((row (guarded (provider-name adapter) 'lookup id
                         (lambda () ((provider-lookup adapter) native-id)))))
             (and row (project fields (describe inspector row fields)))))))
         (lambda (row warnings) `((session . ,row) (warnings . ,warnings))))))
    (_ (error "Expected provider:session-id" id))))

(define* (session-changes #:optional cursor #:key provider status (fields %overview)
                          (inspector (force %default-inspector)))
  "Return a baseline or changed/removed rows and a cursor for this query."
  (validate-query inspector provider status fields)
  (let* ((fields (delete-duplicates (cons 'id fields)))
         (query (list provider status fields))
         (previous (and cursor (assoc-ref (inspector-snapshots inspector) cursor))))
    (when (and cursor (or (not previous) (not (equal? query (car previous)))))
      (error "Expired, foreign, or mismatched session cursor; call session-changes without a cursor"))
    (call-with-values (lambda () (collect (lambda () (scan inspector provider status fields))))
      (lambda (rows warnings)
        (let* ((old (if previous (cdr previous) '()))
               (failed (map (lambda (warning) (assq-ref warning 'provider)) warnings))
               (ids (map (lambda (row) (assq-ref row 'id)) rows))
               (retained (filter (lambda (row) (and (memq (assq-ref row 'provider) failed)
                                                   (not (member (assq-ref row 'id) ids)))) old))
               (current (append rows retained))
               (current-ids (map (lambda (row) (assq-ref row 'id)) current))
               (changed (filter-map (lambda (row)
                 (let* ((id (assq-ref row 'id))
                        (prior (find (lambda (item) (equal? id (assq-ref item 'id))) old))
                        (selected (project fields row)))
                   (and (or (not prior) (not (equal? selected (project fields prior)))) selected))) rows))
               (removed (filter-map (lambda (row) (let ((id (assq-ref row 'id)))
                                                    (and (not (member id current-ids)) id))) old))
               (next (+ 1 (inspector-sequence inspector)))
               (token (format #f "~a/~a" (inspector-generation inspector) next)))
          (set-inspector-sequence! inspector next)
          (set-inspector-snapshots! inspector
            (take (acons token (cons query current) (inspector-snapshots inspector))
                  (min 32 (+ 1 (length (inspector-snapshots inspector))))))
          `((cursor . ,token) (changed . ,changed) (removed . ,removed) (warnings . ,warnings)))))))

(define (install-session-bindings! module)
  (let ((inspector (make-session-inspector)))
    (for-each (lambda (binding)
      (module-define! module (car binding)
        (lambda args (apply (cdr binding) (append args (list #:inspector inspector))))))
      `((session-list . ,session-list) (session-ref . ,session-ref) (session-changes . ,session-changes)))))
