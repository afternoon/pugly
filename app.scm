;;; app.scm --- external state store + component cells and stubs.

;; --- external keyed store ---------------------------------------------------
;; State lives here, never inside a component instance, so redefining a
;; component preserves its state for free.

(define *store* (new Map))

(define (store-key key) (repr key #t))

(define (state-cell key default)
  (let ((k (store-key key)))
    (if (--> *store* (has k))
        (--> *store* (get k))
        (let ((c (signal default)))
          (--> *store* (set k c))
          c))))

(define (state key default) (car (state-cell key default)))

(define (state-set! key value)
  ((cdr (state-cell key value)) value))

(define (store-keys) (--> Array (from (--> *store* (keys)))))

;; --- component registry -----------------------------------------------------
;; Each component name owns a signal holding its definition. Calling the stub
;; reads that cell, so instances subscribe and a redefinition is an ordinary
;; signal write.

(define *components* (new Map))
(define *app-env* #f)
(define (set-app-env! e) (set! *app-env* e))

(define-record-type comp-node
  (make-comp-node name args)
  comp-node?
  (name comp-node-name)
  (args comp-node-args))

(define (name->key name) (if (string? name) name (symbol->string name)))

(define (component-cell name)
  (let ((k (name->key name)))
    (if (--> *components* (has k))
        (--> *components* (get k))
        (let ((c (signal #f)))
          (--> *components* (set k c))
          (bind-stub! k)
          c))))

;; The stub's identity never changes; only the cell contents do. App code
;; therefore cannot capture a stale definition.
(define (bind-stub! k)
  (when *app-env*
    (--> *app-env* (set k (lambda args (make-comp-node k args))))))

(define (define-component! name proc)
  (let ((cell (component-cell name)))
    ((cdr cell) proc)
    (name->key name)))

(define (component-names) (--> Array (from (--> *components* (keys)))))

;; Forward references: a name used before it is defined gets an empty cell and
;; a stub, so defining it later fixes the render by the same signal-write path.
(define (ensure-component! name) (component-cell name) #t)
