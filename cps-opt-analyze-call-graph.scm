;;;; Cyclone Scheme
;;;; https://github.com/justinethier/cyclone
;;;;
;;;; Copyright (c) 2014-2019, Justin Ethier
;;;; All rights reserved.
;;;;
;;;; This file is part of the cps-optimizations module.
;;;;

(cond-expand 
  (program
    (import (scheme base) 
            (scheme write) 
            (scheme cyclone ast) 
            (scheme cyclone primitives)
            (scheme cyclone util) 
            (scheme cyclone pretty-print)
            (srfi 69)
            )))

;; TODO:
;; analyze call graph. not exactly sure how this is going to work yet, but the goal is to be able to figure out which
;; variables a primitive call is dependent upon. We then need to be able to query if any of those variables are mutated 
;; (ideally in fnc body) in which case we cannot inline the prim call.
;; 
;; Notes:
;; Should we pass a copy of the current call graph and then dump it off when a new variable is encountered? In which case, when do we reset the graph? Maybe we just build it up as an a-list as we go, so it resets itself automatically? Then each a-list can exist as part of analysis DB for the variable... would that work?

#;(define (analyze:build-call-graph sexp)
  ;; Add new entry for each var as it is found...
  (define lookup-tbl (make-hash-table))

  ;; Pass over the sexp
  ;; exp - S-expression to scan
  ;; vars - alist of current set of variables
  (define (scan exp vars)
    ;(write `(DEBUG scan ,exp)) (newline)
    (cond
     ((ast:lambda? exp)
      (for-each
        (lambda (a)
          (scan a vars))
        (ast:lambda-args exp))
      (for-each
        (lambda (e)
          (scan e vars))
        (ast:lambda-body exp))
     )
     ((quote? exp) #f)
     ((const? exp) #f)
     ((ref? exp) 
      (hash-table-set! lookup-tbl ref vars)
     )
     ((define? exp) 
      (scan (define->exp exp) '()))
     ((set!? exp)
      ;; TODO: probably need to keep track of var here
      (scan (set!->var exp) vars)
      (scan (set!->exp exp) vars))
     ((if? exp)       
      (scan (if->condition exp) vars)
      (scan (if->then exp) vars)
      (scan (if->else exp) vars))
     ((app? exp)
      (cond
       ((ast:lambda? (car exp))
        ;; TODO: reset vars???
        (for-each
          (lambda (e)
            (scan e '()))
          (cdr exp)))
       (else
         TODO: no, need to collect vars, and pass them to cont (second arg). car can be ignored
         (for-each
          (lambda (e)
            (scan e vars))
          (cdr exp)))))
     (else (error "unknown expression type: " exp))
  ))
  (scan sexp '())
  lookup-tbl)


(cond-expand
  (program
    (define sexp
'(

 (define test
   (lambda
     (k$38 obj$5$11)
     (queue->list
       (lambda
         (r$42)
         ((lambda
            (r$39)
            ((lambda
               (m$6$12)
               (queue-put!
                 (lambda
                   (r$40)
                   (queue-put!
                     (lambda (r$41) (k$38 m$6$12))
                     object-queue
                     obj$5$11))
                 objects-dumped
                 obj$5$11))
             r$39))
          (length r$42)))
       objects-dumped)))

 ;; Doesn't really matter, but lets leave this for now
 (define slot-set!
   (lambda
     (k$7170
       name$2424$3603
       obj$2425$3604
       idx$2426$3605
       val$2427$3606)
     ((lambda
        (vec$2428$3607)
        ((lambda
           (r$7171)
           (k$7170
             (vector-set! r$7171 idx$2426$3605 val$2427$3606)))
         (vector-ref vec$2428$3607 2)))
      obj$2425$3604)))
 )

)

    (pretty-print
      (ast:ast->pp-sexp
        (ast:sexp->ast sexp)))
    
    ;(pretty-print
    ;  (ast:ast->pp-sexp
    ;    (opt:local-var-reduction (ast:sexp->ast sexp)))
    ;)
))
