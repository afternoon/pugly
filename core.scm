;;; core.scm --- fine-grained reactive core
;;; track / mark / propagate with two-colour marking and paired slot arrays.

(define CLEAN 0)
(define STALE 1)
(define PENDING 2)

(define KIND-SIGNAL 0)
(define KIND-MEMO 1)
(define KIND-EFFECT 2)

;; One record serves signals, memos and effects so that linking code does not
;; need to dispatch on type. Numbers, not symbols: symbol identity through
;; record fields is not reliable here.
(define-record-type node
  (make-node kind fn value state sources source-slots observers observer-slots
             owner children cleanups err updated-at)
  node?
  (kind node-kind)
  (fn node-fn set-node-fn!)
  (value node-value set-node-value!)
  (state node-state set-node-state!)
  (sources node-sources)
  (source-slots node-source-slots)
  (observers node-observers)
  (observer-slots node-observer-slots)
  (owner node-owner set-node-owner!)
  (children node-children)
  (cleanups node-cleanups)
  (err node-err set-node-err!)
  (updated-at node-updated-at set-node-updated-at!))

;; --- growable arrays (JS arrays underneath) ---------------------------------
(define (av) (vector))
(define (av-push! a x) (--> a (push x)))
(define (av-pop! a) (--> a (pop)))
(define (av-len a) (vector-length a))
(define (av-ref a i) (vector-ref a i))
(define (av-set! a i v) (vector-set! a i v))
(define (av-clear! a) (set-obj! a 'length 0))

;; --- globals ----------------------------------------------------------------
(define *listener* #f)
(define *owner* #f)
(define *updates* #f)
(define *effects* #f)
(define *exec-count* 0)

(define (pure? n) (= (node-kind n) KIND-MEMO))
(define (computation? n) (not (= (node-kind n) KIND-SIGNAL)))

(define (new-signal v)
  (make-node KIND-SIGNAL #f v CLEAN (av) (av) (av) (av) #f (av) (av) #f 0))

(define (new-computation kind fn)
  (let ((n (make-node kind fn #f STALE (av) (av) (av) (av)
                      *owner* (av) (av) #f 0)))
    (when *owner* (av-push! (node-children *owner*) n))
    n))

;; --- tracking ---------------------------------------------------------------
(define (link! source obs)
  (let ((s-len (av-len (node-observers source)))
        (o-len (av-len (node-sources obs))))
    (av-push! (node-sources obs) source)
    (av-push! (node-source-slots obs) s-len)
    (av-push! (node-observers source) obs)
    (av-push! (node-observer-slots source) o-len)))

(define (read-node n)
  (when (and (computation? n) (not (= (node-state n) CLEAN)))
    (if (= (node-state n) STALE)
        (update-computation n)
        (let ((saved *updates*))
          (set! *updates* #f)
          (run-updates (lambda () (look-upstream n #f)) #f)
          (set! *updates* saved))))
  (when *listener* (link! n *listener*))
  (node-value n))

;; --- writing ----------------------------------------------------------------
(define (write-node! n v)
  (if (equal? (node-value n) v)
      v
      (begin
        (set-node-value! n v)
        (when (> (av-len (node-observers n)) 0)
          (run-updates
           (lambda ()
             (let loop ((i 0))
               (when (< i (av-len (node-observers n)))
                 (let ((o (av-ref (node-observers n) i)))
                   (unless (= (node-state o) STALE)
                     (queue-node! o)
                     (when (> (av-len (node-observers o)) 0) (mark-downstream o))
                     (set-node-state! o STALE)))
                 (loop (+ i 1)))))
           #f))
        v)))

(define (queue-node! o)
  (if (pure? o)
      (when *updates* (av-push! *updates* o))
      (when *effects* (av-push! *effects* o))))

(define (mark-downstream n)
  (let loop ((i 0))
    (when (< i (av-len (node-observers n)))
      (let ((o (av-ref (node-observers n) i)))
        (when (= (node-state o) CLEAN)
          (set-node-state! o PENDING)
          (queue-node! o)
          (when (> (av-len (node-observers o)) 0) (mark-downstream o))))
      (loop (+ i 1)))))

;; --- propagation ------------------------------------------------------------
(define (run-updates fn init)
  (if *updates*
      (fn)
      (let ((wait #f))
        (unless init (set! *updates* (av)))
        (if *effects* (set! wait #t) (set! *effects* (av)))
        (set! *exec-count* (+ *exec-count* 1))
        (let ((res (fn)))
          (complete-updates wait)
          res))))

(define (complete-updates wait)
  (when *updates*
    (run-queue *updates*)
    (set! *updates* #f))
  (unless wait
    (let ((e *effects*))
      (set! *effects* #f)
      (when (and e (> (av-len e) 0))
        (run-updates (lambda () (run-effects e)) #f)))))

(define (run-queue q)
  (let loop ((i 0))
    (when (< i (av-len q))
      (run-top (av-ref q i))
      (loop (+ i 1)))))

(define (run-effects e)
  (let loop ((i 0))
    (when (< i (av-len e))
      (run-top (av-ref e i))
      (loop (+ i 1)))))

;; Climb the OWNER chain (not the dependency chain): a parent about to re-run
;; will dispose and recreate its children, so settle outermost first.
(define (run-top n)
  (cond
   ((= (node-state n) CLEAN) #f)
   ((= (node-state n) PENDING) (look-upstream n #f))
   (else
    (let ((ancestors (av)))
      (av-push! ancestors n)
      (let climb ((c (node-owner n)))
        (when (and c (< (node-updated-at c) *exec-count*))
          (when (not (= (node-state c) CLEAN)) (av-push! ancestors c))
          (climb (node-owner c))))
      (let loop ((i (- (av-len ancestors) 1)))
        (when (>= i 0)
          (let ((c (av-ref ancestors i)))
            (cond
             ((= (node-state c) STALE) (update-computation c))
             ((= (node-state c) PENDING)
              (look-upstream c (av-ref ancestors 0)))
             (else #f)))
          (loop (- i 1))))))))

;; Optimistically clean, settle every dirty source; if one of them writes a new
;; value it will mark us STALE again on the way through and we recompute.
(define (look-upstream n ignore)
  (set-node-state! n CLEAN)
  (let loop ((i 0))
    (when (< i (av-len (node-sources n)))
      (let ((s (av-ref (node-sources n) i)))
        (when (computation? s)
          (cond
           ((= (node-state s) STALE)
            (when (and (not (eq? s ignore)) (< (node-updated-at s) *exec-count*))
              (run-top s)))
           ((= (node-state s) PENDING) (look-upstream s ignore))
           (else #f))))
      (loop (+ i 1)))))

(define (update-computation n)
  (when (node-fn n)
    (clean-node n)
    (let ((time *exec-count*)
          (prev-listener *listener*)
          (prev-owner *owner*))
      (set! *listener* n)
      (set! *owner* n)
      (run-computation n time)
      (set! *listener* prev-listener)
      (set! *owner* prev-owner))))

;; Per-effect error isolation: a thrown error marks this node and is reported,
;; but the queue keeps draining so the rest of the app stays live.
(define (run-computation n time)
  ;; NOT `guard`: LIPS compiles guard to try, which always returns a Promise
  ;; and would make propagation asynchronous. js-try is a real synchronous
  ;; try/catch in the host shim.
  (let ((next (js-try
               (lambda ()
                 (set-node-err! n #f)
                 ((node-fn n) (node-value n)))
               (lambda (e)
                 (set-node-err! n (js-error-message e))
                 (report-node-error n e)
                 'error))))
    (when (<= (node-updated-at n) time)
      (if (pure? n)
          (write-node! n next)
          (set-node-value! n next))
      (set-node-updated-at! n time))))

;; replaced by the renderer so errors can be shown in place
(define *error-reporter* (lambda (n e) #f))
(define (report-node-error n e) (*error-reporter* n e))
(define (set-error-reporter! f) (set! *error-reporter* f))

(define (clean-node n)
  (let loop ()
    (when (> (av-len (node-sources n)) 0)
      (let* ((source (av-pop! (node-sources n)))
             (index (av-pop! (node-source-slots n)))
             (obs (node-observers source)))
        (when (> (av-len obs) 0)
          ;; swap-remove using the paired slot index: O(1), no scan
          (let ((last (av-pop! obs))
                (slot (av-pop! (node-observer-slots source))))
            (when (< index (av-len obs))
              (av-set! (node-source-slots last) slot index)
              (av-set! obs index last)
              (av-set! (node-observer-slots source) index slot)))))
      (loop)))
  (let loop ((i (- (av-len (node-children n)) 1)))
    (when (>= i 0)
      (clean-node (av-ref (node-children n) i))
      (loop (- i 1))))
  (av-clear! (node-children n))
  (let loop ((i 0))
    (when (< i (av-len (node-cleanups n)))
      ((av-ref (node-cleanups n) i))
      (loop (+ i 1))))
  (av-clear! (node-cleanups n))
  (set-node-state! n CLEAN))

;; --- public API -------------------------------------------------------------
(define (signal init)
  (let ((n (new-signal init)))
    (cons (lambda () (read-node n))
          (lambda (v) (run-updates (lambda () (write-node! n v)) #f)))))

(define (memo fn)
  (let ((n (new-computation KIND-MEMO (lambda (prev) (fn)))))
    (update-computation n)
    (lambda () (read-node n))))

(define (effect fn)
  (let ((n (new-computation KIND-EFFECT (lambda (prev) (fn)))))
    (if *effects*
        (av-push! *effects* n)
        (run-updates (lambda () (update-computation n)) #f))
    n))

(define (batch fn) (run-updates fn #f))

(define (on-cleanup! fn)
  (when *owner* (av-push! (node-cleanups *owner*) fn)))

;; Like root, but not registered as a child of the current owner: used for
;; keyed list rows, which must survive their parent effect re-running.
(define (detached-root fn)
  (let ((prev-owner *owner*))
    (set! *owner* #f)
    (let ((res (root fn)))
      (set! *owner* prev-owner)
      res)))

(define (root fn)
  (let ((n (new-computation KIND-EFFECT #f)))
    (set-node-state! n CLEAN)
    (set-node-updated-at! n *exec-count*)
    (let ((prev-owner *owner*) (prev-listener *listener*))
      (set! *owner* n)
      (set! *listener* #f)
      (let ((res (fn n)))
        (set! *owner* prev-owner)
        (set! *listener* prev-listener)
        res))))
