;;; dom.scm --- thin Scheme wrappers over the JS DOM shim.
;;; The shim (see host JS) does the string coercion, because LIPS strings are
;;; boxed objects and the DOM needs primitives.

(define (dom-create tag) (js-create tag))
(define (dom-text s) (js-text s))
(define (dom-fragment) (js-fragment))
(define (dom-append parent child) (js-append parent child))
(define (dom-insert-before parent node ref) (js-insert-before parent node ref))
(define (dom-parent node) (js-parent node))
(define (dom-set-text! node s) (js-set-text node s))
(define (dom-set-attr! node name value) (js-set-attr node name value))
(define (dom-on! node event handler) (js-on node event handler))
(define (dom-clear! node) (js-clear node))
(define (dom-children-array node) (js-children node))
(define (dom-remove-nodes! nodes) (js-remove-nodes nodes))
(define (dom-insert-nodes-before! parent nodes ref)
  (js-insert-nodes parent nodes ref))

(define (->text v)
  (cond ((string? v) v)
        ((number? v) (number->string v))
        ((eq? v #t) "#t")
        ((eq? v #f) "")
        ((null? v) "")
        (else (repr v))))
