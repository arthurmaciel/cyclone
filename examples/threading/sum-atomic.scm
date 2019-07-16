;;;; Example of having multiple threads sum a variable using an atom.
(import (scheme base)
        (scheme read)
        (scheme write)
        (cyclone concurrent)
        (srfi 18))

;(define cv (make-condition-variable))
;(define m (make-mutex))

(define *sum* (make-atom 0.0))

(define (sum-loop n)
  ;;(set! *sum* (+ *sum* 1))
  (swap! *sum* + 1)
  (if (zero? n)
      'done
      (sum-loop (- n 1))))

(define (sum-entry-pt)
  (sum-loop (* 100 100 100)))

;; Thread - Do something, then let main thread know when we are done
(define t1 (make-thread sum-entry-pt))
(define t2 (make-thread sum-entry-pt))
(define t3 (make-thread sum-entry-pt))
(define t4 (make-thread sum-entry-pt))
(define t5 (make-thread sum-entry-pt))
(define t6 (make-thread sum-entry-pt))
(define t7 (make-thread sum-entry-pt))
(define t8 (make-thread sum-entry-pt))
(define t9 (make-thread sum-entry-pt))
(thread-start! t1)
(thread-start! t2)
(thread-start! t3)
(thread-start! t4)
(thread-start! t5)
(thread-start! t6)
(thread-start! t7)
(thread-start! t8)
(thread-start! t9)

(thread-join! t1)
(thread-join! t2)
(thread-join! t3)
(thread-join! t4)
(thread-join! t5)
(thread-join! t6)
(thread-join! t7)
(thread-join! t8)
(thread-join! t9)
(display "main thread done, sum = ")
(display (deref *sum*))
(newline)
