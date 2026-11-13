(define-module (weft advice)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (make-advice advice-call install-advice-bindings!))

(define (make-advice) (vector '()))

(define (advice-call registry module target original arguments)
  "Invoke named advice, resolving its procedure at each call."
  (let ((entries (filter (lambda (entry) (eq? target (cadr entry)))
                         (reverse (vector-ref registry 0)))))
    (let loop ((entries entries))
      (if (null? entries)
          (apply original arguments)
          (match (car entries)
            ((name target kind command)
             (let ((procedure (module-ref module command))
                   (next (lambda () (loop (cdr entries)))))
               (case kind
                 ((before) (apply procedure arguments) (next))
                 ((after)
                  (call-with-values next
                    (lambda results
                      (apply procedure arguments)
                      (apply values results))))
                 ((around) (apply procedure next arguments))))))))))

(define (install-advice-bindings! registry module)
  (module-define! module 'advice-add!
    (lambda (name target kind command)
      (unless (and (symbol? name) (symbol? target) (symbol? command)
                   (memq kind '(before after around)))
        (error "Expected advice name, target, before/after/around, and command symbol"))
      (let ((entries (vector-ref registry 0)))
        (when (and (not (assq name entries)) (>= (length entries) 128))
          (error "Advice limit reached"))
        (vector-set! registry 0
                     (acons name (list target kind command) (alist-delete name entries))))
      name))
  (module-define! module 'advice-remove!
    (lambda (name)
      (vector-set! registry 0 (alist-delete name (vector-ref registry 0))) #t))
  (module-define! module 'advice-list
    (lambda () (map list-copy (vector-ref registry 0)))))
