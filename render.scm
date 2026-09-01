;;; render.scm --- SXML -> DOM, fine grained.

(define-record-type each-node
  (make-each-node items key-proc render-proc)
  each-node?
  (items each-node-items)
  (key-proc each-node-key-proc)
  (render-proc each-node-render-proc))

(define (each items key-proc render-proc)
  (make-each-node items key-proc render-proc))

(define (attrs-block? x)
  (and (pair? x) (symbol? (car x)) (string=? (symbol->string (car x)) "@")))

;; --- children ---------------------------------------------------------------
(define (render-child parent child)
  (cond
   ((procedure? child) (render-hole parent child))
   ((comp-node? child) (render-component parent child))
   ((each-node? child) (render-each parent child))
   ((string? child) (dom-append parent (dom-text child)))
   ((number? child) (dom-append parent (dom-text (number->string child))))
   ((null? child) #f)
   ((pair? child)
    (if (symbol? (car child))
        (render-element parent child)
        (for-each (lambda (c) (render-child parent c)) child)))
   ((eq? child #f) #f)
   (else (dom-append parent (dom-text (->text child))))))

(define (render-element parent sxml)
  (let* ((tag (car sxml))
         (rest (cdr sxml))
         (el (dom-create (symbol->string tag))))
    (let ((body (if (and (pair? rest) (attrs-block? (car rest)))
                    (begin (apply-attrs! el (cdr (car rest))) (cdr rest))
                    rest)))
      (for-each (lambda (c) (render-child el c)) body))
    (dom-append parent el)
    el))

(define (apply-attrs! el attrs)
  (for-each
   (lambda (a)
     (let* ((name (symbol->string (car a)))
            (value (if (pair? (cdr a)) (car (cdr a)) (cdr a))))
       (if (and (>= (string-length name) 3)
                (string=? (substring name 0 3) "on-"))
           (dom-on! el (substring name 3 (string-length name)) value)
           (if (procedure? value)
               (effect (lambda () (dom-set-attr! el name (->text (value)))))
               (dom-set-attr! el name (->text value))))))
   attrs))

;; A bare procedure in child position is a reactive hole: its own effect
;; writing into its own text node.
(define (render-hole parent thunk)
  (let ((tn (dom-text "")))
    (dom-append parent tn)
    (effect (lambda () (dom-set-text! tn (->text (thunk)))))
    tn))

;; --- components -------------------------------------------------------------
;; Reading the cell subscribes this effect, so a redefinition re-renders just
;; this subtree; cleanup removes the nodes the previous definition made.
(define (render-component parent cn)
  (let ((marker (dom-text "")))
    (dom-append parent marker)
    (effect
     (lambda ()
       (let* ((cell (component-cell (comp-node-name cn)))
              (proc ((car cell)))
              (frag (dom-fragment)))
         (if proc
             (render-child frag (apply proc (comp-node-args cn)))
             (render-child frag (string-append "[ " (comp-node-name cn)
                                               " is not defined ]")))
         (let ((nodes (dom-children-array frag))
               (p (dom-parent marker)))
           (dom-insert-before p frag marker)
           (on-cleanup! (lambda () (dom-remove-nodes! nodes)))))))
    marker))

;; --- keyed lists ------------------------------------------------------------
;; Reconcile by key: create new keys, dispose missing ones, move survivors.
;; Never rebuild the list.
(define (render-each parent en)
  (let ((marker (dom-text ""))
        (rows '()))               ; list of (key nodes owner)
    (dom-append parent marker)
    ;; rows outlive each re-run, so they are disposed here, not by the effect
    (on-cleanup! (lambda ()
                   (for-each (lambda (row)
                               (clean-node (car (cdr (cdr row))))
                               (dom-remove-nodes! (car (cdr row))))
                             rows)
                   (set! rows '())))
    (effect
     (lambda ()
       (let* ((items ((each-node-items en)))
              (p (dom-parent marker))
              (old rows)
              (new '()))
         (for-each
          (lambda (item)
            (let* ((k (store-key ((each-node-key-proc en) item)))
                   (hit (assoc k old)))
              (if hit
                  (set! new (cons hit new))
                  (let* ((frag (dom-fragment))
                         (owner (detached-root
                                 (lambda (owner)
                                   (render-child frag
                                                 ((each-node-render-proc en) item))
                                   owner))))
                    (set! new (cons (list k (dom-children-array frag) owner)
                                    new))))))
          items)
         (set! new (reverse new))
         ;; dispose rows whose key vanished
         (for-each
          (lambda (row)
            (unless (assoc (car row) new)
              (clean-node (car (cdr (cdr row))))
              (dom-remove-nodes! (car (cdr row)))))
          old)
         ;; place every surviving row in order; moving is idempotent
         (for-each
          (lambda (row)
            (dom-insert-nodes-before! p (car (cdr row)) marker))
          new)
         (set! rows new))))
    marker))

;; --- mounting ---------------------------------------------------------------
;; Called once at startup, before any app code exists. The forward-reference
;; path supplies a placeholder until the buffer defines `main`.
(define *root-node* #f)

(define (mount! root-el)
  (dom-clear! root-el)
  (set! *root-node*
        (root (lambda (owner)
                (render-child root-el (make-comp-node "main" '()))
                owner)))
  *root-node*)

;; --- inspector --------------------------------------------------------------
;; The owner tree is already the live instance hierarchy. Render it directly
;; rather than keeping a parallel scene graph.

(define (node-label n)
  (string-append
   (cond ((= (node-kind n) KIND-MEMO) "memo")
         ((= (node-kind n) KIND-EFFECT) "effect")
         (else "signal"))
   "  <- " (number->string (av-len (node-sources n))) " src"
   (if (node-err n) (string-append "   ! " (node-err n)) "")))

(define (spaces n)
  (let loop ((i 0) (s ""))
    (if (>= i n) s (loop (+ i 1) (string-append s " ")))))

(define (inspect-text)
  (if (not *root-node*)
      "not mounted"
      (let ((out ""))
        (let walk ((n *root-node*) (depth 0))
          (set! out (string-append out (spaces (* depth 2))
                                   (if (= depth 0) "" "- ")
                                   (node-label n) "\n"))
          (let ((kids (node-children n)))
            (let loop ((i 0))
              (when (< i (av-len kids))
                (walk (av-ref kids i) (+ depth 1))
                (loop (+ i 1))))))
        out)))
