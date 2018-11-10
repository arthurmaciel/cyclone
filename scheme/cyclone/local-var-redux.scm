;;;; Cyclone Scheme
;;;; https://github.com/justinethier/cyclone
;;;;
;;;; Copyright (c) 2014-2018, Justin Ethier
;;;; All rights reserved.
;;;;
;;;; This file is part of the cps-optimizations module.
;;;;

(cond-expand 
  (program
    (import (scheme base) 
            (scheme write) 
            (scheme cyclone ast) 
            (scheme cyclone util) 
            (scheme cyclone pretty-print))))

;; Local variable reduction:
;; Reduce given sexp by replacing certain lambda calls with a let containing
;; local variables. Based on the way cyclone transforms code, this will
;; typically be limited to if expressions embedded in other expressions.
(define (opt:local-var-reduction sexp)
  (define (scan exp)
    (cond
     ((ast:lambda? exp)
      (ast:%make-lambda
        (ast:lambda-id exp)
        (ast:lambda-args exp)
        (map scan (ast:lambda-body exp))
        (ast:lambda-has-cont exp)))
     ((quote? exp) exp)
     ((const? exp) exp)
     ((ref? exp) exp)
     ((define? exp) 
      `(define
        ,(define->var exp)
        ,(map scan (define->exp exp))))
     ((set!? exp)
      `(set!
         ,(set!->var exp)
         ,(set!->exp exp)))
     ((if? exp)       
      `(if ,(scan (if->condition exp))
           ,(scan (if->then exp))
           ,(scan (if->else exp))))
     ((app? exp)
      (cond
        ((and
          (ast:lambda? (car exp))
          (equal? (length exp) 2)
          (ast:lambda? (cadr exp))
          (equal? 1 (length (ast:lambda-args (cadr exp))))
          (lvr:local-tail-call-only? 
            (ast:lambda-body (car exp)) 
            (car (ast:lambda-args (car exp)))))
         ;;(write `(tail-call-only? passed for ,exp)) (newline)
         ;;(write `(replace with ,(lvr:tail-calls->values 
         ;;                         (car (ast:lambda-body (car exp)))
         ;;                         (car (ast:lambda-args (car exp))))))
         ;;(newline)
         (let ((value (lvr:tail-calls->values
                        (car (ast:lambda-body (car exp)))
                        (car (ast:lambda-args (car exp)))))
               (var (car (ast:lambda-args (cadr exp))))
               (body (ast:lambda-body (cadr exp))))
          `(let ((,var ,value))
            ,@body)))
        (else
          (map scan exp))))
     (else (error "unknown expression type: " exp))
  ))
  (scan sexp))

;; Local variable reduction helper:
;; Scan sexp to determine if sym is only called in a tail-call position
(define (lvr:local-tail-call-only? sexp sym)
  (call/cc
    (lambda (return)
      (define (scan exp fail?)
        (cond
         ((ast:lambda? exp)
          (return #f)) ;; Could be OK if not ref'd...
         ;((quote? exp) exp)
         ;((const? exp) exp)
         ((ref? exp) 
          (if (equal? exp sym)
              (return #f))) ;; Assume not a tail call
         ((define? exp) 
          (return #f)) ;; Fail fast
         ((set!? exp)
          (return #f)) ;; Fail fast
         ((if? exp)       
          (scan (if->condition exp) #t) ;; fail if found under here
          (scan (if->then exp) fail?)
          (scan (if->else exp) fail?))
         ((app? exp)
          (cond
            ((and (equal? (car exp) sym)
                  (not fail?))
             (map (lambda (e) (scan e fail?)) (cdr exp))) ;; Sym is OK, skip
            (else
             (map (lambda (e) (scan e fail?)) exp))))
         (else exp)))
      (scan sexp #f)
      (return #t))))

;; Local variable reduction helper:
;; Transform all tail calls of sym in the sexp to just the value passed
(define (lvr:tail-calls->values sexp sym)
  (call/cc
    (lambda (return)
      (define (scan exp)
        ;;(write `(DEBUG scan ,exp)) (newline)
        (cond
         ((ast:lambda? exp)
          (return #f)) ;; Could be OK if not ref'd...
         ((ref? exp) 
          (if (equal? exp sym)
              (return #f))) ;; Assume not a tail call
         ((define? exp) 
          (return #f)) ;; Fail fast
         ((set!? exp)
          (return #f)) ;; Fail fast
         ((if? exp)       
          `(if ,(if->condition exp) 
               ,(scan (if->then exp))
               ,(scan (if->else exp))))
         ((app? exp)
          (cond
            ((and (equal? (car exp) sym)
                  (= (length exp) 2)
             )
             (cadr exp))
            (else
             (return #f))))
         (else exp)))
      (return
        (scan sexp)))))

(cond-expand
  (program
    (define sexp
                 '(lambda
                    (k$1073 i$88$682 first$89$683 row$90$684)
                    (if (Cyc-fast-eq
                          i$88$682
                          number-of-cols$68$671)
                      (k$1073
                        (Cyc-fast-eq
                          i$88$682
                          number-of-cols$68$671))
                      ((lambda
                         (k$1080)
                         (if (Cyc-fast-eq
                               (car first$89$683)
                               (car row$90$684))
                           (k$1080 if-equal$76$674)
                           (k$1080 if-different$77$675)))
                       (lambda
                         (r$1079)
                         (Cyc-seq
                           (vector-set!
                             vec$79$677
                             i$88$682
                             r$1079)
                           ((cell-get lp$80$87$681)
                            k$1073
                            (Cyc-fast-plus i$88$682 1)
                            (cdr first$89$683)
                            (cdr row$90$684))))))))
    
    ;(pretty-print
    ;  (ast:ast->pp-sexp
    ;    (ast:sexp->ast sexp)))
    
    (pretty-print
      (ast:ast->pp-sexp
        (opt:local-var-reduction (ast:sexp->ast sexp))))
    ))
