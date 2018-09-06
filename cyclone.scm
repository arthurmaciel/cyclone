;;;; Cyclone Scheme
;;;; https://github.com/justinethier/cyclone
;;;;
;;;; Copyright (c) 2014-2016, Justin Ethier
;;;; All rights reserved.
;;;;
;;;; This module contains a front-end for the compiler itself.
;;;;
(import (scheme base)
        (scheme case-lambda)
        (scheme eval)
        (scheme file)
        (scheme lazy)
        (scheme read)
        (scheme write)
        (scheme cyclone ast)
        (scheme cyclone common)
        (scheme cyclone util)
        (scheme cyclone cgen)
        (scheme cyclone primitives)
        (scheme cyclone transforms)
        (scheme cyclone cps-optimizations)
        (scheme cyclone libraries))

(define *optimization-level* 2) ;; Default level

;; Code emission.
  
; c-compile-and-emit : (string -> A) exp -> void
(define (c-compile-and-emit input-program program:imports/code 
                            lib-deps change-lib-deps! src-file append-dirs prepend-dirs)
  (call/cc 
    (lambda (return)
      (define globals '())
      (define module-globals '()) ;; Globals defined by this module
      (define program? #t) ;; Are we building a program or a library?
      (define imports '())
      (define inlines '())
      (define imported-vars '())
      (define lib-name '())
      (define lib-exports '())
      (define lib-renamed-exports '())
      (define lib-pass-thru-exports '())
      (define c-headers '())
      (define rename-env (env:extend-environment '() '() '()))

      (emit *c-file-header-comment*) ; Guarantee placement at top of C file
    
      (trace:info "---------------- input program:")
      (trace:info input-program) ;pretty-print

      (cond
        ((library? (car input-program))
         (let ((includes (lib:includes (car input-program))))
           (set! program? #f)
           (set! lib-name (lib:name (car input-program)))
           (set! c-headers (lib:include-c-headers (car input-program)))
           (set! inlines (lib:inlines (car input-program)))
           (set! lib-exports
             (cons
               (lib:name->symbol lib-name)
               (lib:exports (car input-program))))
           (set! lib-pass-thru-exports lib-exports)
           (set! lib-renamed-exports 
             (lib:rename-exports (car input-program)))
           (set! imports (lib:imports (car input-program)))
           (set! input-program (lib:body (car input-program)))
           ;; Add any renamed exports to the begin section
           (set! input-program
                 (append
                   (map 
                     (lambda (r) 
                      `(define ,(caddr r) ,(cadr r)))
                     lib-renamed-exports)   
                   input-program))
           ;; Prepend any included files into the begin section
           (if (not (null? includes))
             (for-each
               (lambda (include)
                 (set! input-program 
                       (append (read-file ;(string-append 
                                            (lib:import->path lib-name append-dirs prepend-dirs include) 
                                            ;include)
                       ) 
                               input-program)))
               (reverse includes))))) ;; Append code in same order as the library's includes
        (else
          ;; Handle imports, if present
          (let ((reduction program:imports/code))
            (set! imports (car reduction))
            (set! input-program (cdr reduction)))

          ;;  Handle inline list, if present`
          (let ((lis (lib:inlines `(dummy dummy ,@input-program))))
            (cond
              ((not (null? lis))
               (set! inlines lis)
               (set! input-program 
                     (filter 
                       (lambda (expr)
                         (not (tagged-list? 'inline expr)))
                       input-program)))))

          ;; Handle any C headers
          (let ((headers (lib:include-c-headers `(dummy dummy ,@input-program))))
            (cond
              ((not (null? headers))
               (set! c-headers headers)
               (set! input-program 
                     (filter 
                       (lambda (expr)
                         (not (tagged-list? 'include-c-header expr)))
                       input-program)))))
        ))

      (trace:info "inline candidates:")
      (trace:info inlines)

      ;; Process library imports
      (trace:info "imports:")
      (trace:info imports)
      (set! imported-vars (lib:imports->idb imports append-dirs prepend-dirs))
      (trace:info "resolved imports:")
      (trace:info imported-vars)
      (let ((meta (lib:resolve-meta imports append-dirs prepend-dirs)))
        (set! *defined-macros* (append meta *defined-macros*))
        (trace:info "resolved macros:")
        (trace:info meta))

      ;; TODO: how to handle stdlib when compiling a library??
      ;; either need to keep track of what was actually used,
      ;; or just assume all imports were used and include them
      ;; in final compiled program
      ;(set! input-program (add-libs input-program))
    
      ;; Load macros for expansion phase
      (let ((macros (filter 
                      (lambda (v) 
                        (Cyc-macro? (Cyc-get-cvar (cdr v))))
                      (Cyc-global-vars))))
        (set! *defined-macros*
              (append
                macros
                *defined-macros*)))
      (macro:load-env! *defined-macros* (create-environment '() '()))

      ;; Expand macros
      ;; In each case, the input is expanded in a way that ensures
      ;; defines from any top-level begins are spliced correctly.
      (set! input-program 
        (cond
          (program?
            (expand-lambda-body input-program (macro:get-env) rename-env))
          (else
            (let ((expanded (expand `(begin ,@input-program) 
                                    (macro:get-env)
                                    rename-env)))
              (cond
                ((and (pair? expanded)
                      (tagged-list? 'lambda (car expanded)))
                 (lambda->exp (car expanded)))
                ((tagged-list? 'define expanded)
                 (list expanded))
                ((boolean? expanded)
                 (list expanded))
                (else
                  (error `(Unhandled expansion ,expanded))))))))
      (trace:info "---------------- after macro expansion:")
      (trace:info input-program) ;pretty-print
; TODO:
      (set! input-program (macro:cleanup input-program rename-env))
      (trace:info "---------------- after macro expansion cleanup:")
      (trace:info input-program) ;pretty-print

      ;; If a program, check to see if any macros expanded into top-level imports
      (when program?
        (let ((program:imports/code (import-reduction input-program (base-expander))))
          (when (not (null? (car program:imports/code)))
;(trace:info "debug")
;(trace:info program:imports/code)
            (trace:info "-------------- macro expanded into import expression(s):")
            (set! imports (append imports (car program:imports/code)))
            (trace:info "imports:")
            (trace:info imports)
            (set! imported-vars (lib:imports->idb imports append-dirs prepend-dirs))
            (trace:info "resolved imports:")
            (trace:info imported-vars)
            (let ((meta (lib:resolve-meta imports append-dirs prepend-dirs)))
              (set! *defined-macros* (append meta *defined-macros*))
              (trace:info "resolved macros:")
              (trace:info meta))
            (set! input-program (cdr program:imports/code))
            ;(set! lib-deps (append lib-deps (lib:get-all-import-deps (car program:imports/code) append-dirs prepend-dirs)))
            (let ((new-lib-deps (lib:get-all-import-deps (car program:imports/code) append-dirs prepend-dirs)))
              (for-each
                (lambda (dep)
                  (if (not (member dep lib-deps))
                      (set! lib-deps (cons dep lib-deps))))
                new-lib-deps)
              (change-lib-deps! lib-deps))
            (trace:info lib-deps)
          )))
      ;; END additional top-level imports

      ;; Separate global definitions from the rest of the top-level code
      (set! input-program 
          (isolate-globals input-program program? lib-name rename-env))

      ;; Optimize-out unused global variables
      ;; For now, do not do this if eval is used.
      ;; TODO: do not have to be so aggressive, unless (eval (read)) or such
      (if (not (has-global? input-program 'eval))
          (set! input-program 
            (filter-unused-variables input-program lib-exports)))

      (trace:info "---------------- after processing globals")
      (trace:info input-program) ;pretty-print

      ;; Identify global variables
      (set! module-globals (global-vars input-program))
      (set! globals (append (lib:idb:ids imported-vars) module-globals))

      ;; Register inlinable Scheme functions
      (for-each
        (lambda (e)
          (if (define-c-inline? e)
            (prim:add-udf! (define->var e) (define-c->inline-var e))))
            ;(write `(DEBUG add inline ,(define->var e) ,(define-c->inline-var e)))))
        input-program)

      ;; Inlines do not have to be non-CPS, they are really two separate things.
      ;; So keep track of all functions marked as inline because there are still
      ;; possibilities for optimization even if the function must call into its
      ;; continuation.
      (opt:add-inlinable-functions inlines) 

      ;; Trim down the export list to any exports that are just "pass throughs"
      ;; from imported libraries. That is, they are not actually defined in
      ;; the library being compiled
      (set! lib-pass-thru-exports
        (filter
          (lambda (e)
            (let ((module-global? (member e module-globals))
                  (imported-var? (assoc e imported-vars)))
              (cond
                ((eq? e 'call/cc) #f) ;; Special case
                ((and (not module-global?)
                      (not imported-var?))
                 (error "Identifier is exported but not defined" e))
                (else
                  ;; Pass throughs are not defined in this module,
                  ;; but by definition must be defined in an imported lib
                  (and (not module-global?) imported-var?)))))
          lib-pass-thru-exports))
      (trace:info "pass thru exports:")
      (trace:info lib-pass-thru-exports)
    
      ; Note alpha-conversion is overloaded to convert internal defines to 
      ; set!'s below, since all remaining phases operate on set!, not define.
      ;
      ; TODO: consider moving some of this alpha-conv logic below back into trans?
      (set! input-program 
        (map
          (lambda (expr)
            (alpha-convert expr globals return))
          input-program))
      (trace:info "---------------- after alpha conversion:")
      (trace:info input-program) ;pretty-print

      ;; EXPERIMENTAL CODE - Load functions in other modules that are
      ;; able to be inlined (in this context, from CPS).
      ;;
      ;; TODO: extend this initially by, for each import, invoking that module's inlinable_lambdas function
      ;;       behind an exception handler (in case the compiler does not have that module loaded).
      ;;
      ;;       Longer term, need to test if module is loaded (maybe do that in combo with exception handler above)
      ;;       and if not loaded, eval/import it and try again.
      ;;
      ;; assumes (scheme base) is available to compiler AND at runtime in the compiled module/program
      ;; TODO: probably not good enough since inlines are not in export list
      ;;
      ;; TODO: later on, in cgen, only add inlinables that correspond to exported functions
      
      (for-each
        (lambda (import)
          (with-handler
            (lambda (err)
              #f)
            (let* ((lib-name-str (lib:name->string (lib:list->import-set import)))
                   (inlinable-lambdas-fnc 
                    (string->symbol
                      (string-append "c_" lib-name-str "_inlinable_lambdas"))))
            (cond
              ((imported? import)
               (let ((lib-name (lib:import->library-name 
                                 (lib:list->import-set import)))
                     (vars/inlines
                       (filter
                        (lambda (v/i)
                          ;; Try to avoid name conflicts by not loading inlines
                          ;; that conflict with identifiers in this module.
                          ;; More of a band-aid than a true solution, though.
                          (not (member (car v/i) module-globals)))
                        (eval `( ,inlinable-lambdas-fnc )))))
                 ;(trace:info `(DEBUG ,import ,vars/inlines ,module-globals))
                 ;; Register inlines as user-defined primitives
                 (for-each
                   (lambda (v/i)
                     (let ((var (car v/i)) (inline (cdr v/i)))
                       (prim:add-udf! var inline)))
                   vars/inlines)
                 ;; Keep track of inline version of functions along with other imports
                 (set! imported-vars 
                   (append
                     imported-vars
                     (map
                       (lambda (v/i)
                         (cons (cdr v/i) lib-name))
                       vars/inlines)))))
              (else
                ;; TODO: try loading if not loaded (but need ex handler in case anything bad happens) #t ;(eval `(import ,import))
                ;;(%import import)
                ;; if this work is done, would need to consolidate inline reg code above
                #f)))))
        imports)
      ;; END

      ;; Convert some function calls to primitives, if possible
      (set! input-program 
        (map
          (lambda (expr)
            (prim-convert expr))
          input-program))
      (trace:info "---------------- after func->primitive conversion:")
      (trace:info input-program) ;pretty-print

      ;; Identify native Scheme functions (from module being compiled) that can be inlined
      ;;
      ;; NOTE: There is a chicken-and-egg problem here that prevents this from 
      ;; automatically working 100%. Basically we need to know whether the inline logic will
      ;; work for a given candidate. The problem is, the only way to do that is to run the
      ;; code through CPS and by then we would have to go back and repeat many phases if a
      ;; candidate fails the inline tests. At least for now, an alternative is to require 
      ;; user code to specify (via inline) what functions the compiler should try inlining.
      ;; There is a small chance one of those inlines can pass these tests and still fail
      ;; the subsequent inline checks though, which causes an error in the C compiler.
      (define inlinable-scheme-fncs '())
      (let ((lib-init-fnc (lib:name->symbol lib-name))) ;; safe to ignore for programs
        (for-each
          (lambda (e)
            (when (and (define? e)
                       (member (define->var e) inlines) ;; Primary check, did use request inline
                       (not (equal? (define->var e) lib-init-fnc))
                       (inlinable-top-level-lambda? e)) ;; Failsafe, reject if basic checks fail
              (set! inlinable-scheme-fncs
                (cons (define->var e) inlinable-scheme-fncs))
              (set! module-globals
                (cons (define-c->inline-var e) module-globals))
              (prim:add-udf! (define->var e) (define-c->inline-var e))))
          input-program)
        (trace:info "---------------- results of inlinable-top-level-lambda analysis: ")
        (trace:info inlinable-scheme-fncs))
    
      (let ((cps (map 
                   (lambda (expr)
                     (cps-convert expr))
                   input-program)))
        (cond
         ((and library? (equal? lib-name '(scheme base)))
           (set! globals (append '(call/cc) globals))
           (set! module-globals (append '(call/cc) module-globals))
           (set! input-program 
             ;(cons
             ; ;; Experimental version of call-with-values,
             ; ;; seems OK in compiler but not in eval.
             ; '(define call-with-values
             ;   (lambda (k producer consumer)
             ;     (let ((x (producer)))
             ;       (if (and (pair? x) (equal? '(multiple values) (car x)))
             ;         (apply consumer (cdr x))
             ;         (consumer k x))))
             ;   ;  (producer 
             ;   ;    (lambda (result)
             ;   ;      (consumer k result))))
             ;   )
                    ;; multiple args requires more than just this.
                    ;; may want to look at:
                    ;; http://stackoverflow.com/questions/16674214/how-to-implement-call-with-values-to-match-the-values-example-in-r5rs
                    ;; (lambda vals
                    ;;   (apply k consumer vals)))))
             (cons
               ;; call/cc must be written in CPS form, so it is added here
               ;; TODO: prevents this from being optimized-out
               ;; TODO: will this cause issues if another var is assigned to call/cc?
               `(define call/cc
                 ,(ast:make-lambda 
                    '(k f) 
                    (list 
                      (list 'f 'k 
                            (ast:make-lambda '(_ result) 
                                             (list '(k result)))))))
                 ;(lambda (k f) (f k (lambda (_ result) (k result)))))
                cps)));)
         (else
           ;; No need for call/cc yet
           (set! input-program cps))))
      (trace:info "---------------- after CPS:")
      (trace:info (ast:ast->pp-sexp input-program))

      (when (> *optimization-level* 0)
        (set! input-program
          (optimize-cps input-program))
        (trace:info "---------------- after cps optimizations (1):")
        (trace:info (ast:ast->pp-sexp input-program))

        (set! input-program
          (optimize-cps input-program))
        (trace:info "---------------- after cps optimizations (2):")
        (trace:info (ast:ast->pp-sexp input-program))
        
        (set! input-program
          (optimize-cps input-program))
        (trace:info "---------------- after cps optimizations (3):")
        (trace:info (ast:ast->pp-sexp input-program))
      )
    
      (set! input-program
        (map
          (lambda (expr)
            (clear-mutables)
            (analyze-mutable-variables expr)
            (wrap-mutables expr globals))
          input-program))
      (trace:info "---------------- after wrap-mutables:")
      (trace:info (ast:ast->pp-sexp input-program))
    
      (set! input-program 
        (map
          (lambda (expr)
            (cond
             ((define? expr)
              ;; Global
              `(define ,(define->var expr)
                 ,@(car (ast:lambda-body (closure-convert (define->exp expr) globals *optimization-level*)))))
             ((define-c? expr)
              expr)
             (else
              (car (ast:lambda-body ;; Strip off superfluous lambda
                (closure-convert expr globals *optimization-level*))))))
          input-program))
      (trace:info "---------------- after closure-convert:")
      (trace:info (ast:ast->pp-sexp input-program))
      
      (when (not *do-code-gen*)
        (trace:error "DEBUG, existing program")
        (exit 0))
    
      (trace:info "---------------- C headers: ")
      (trace:info c-headers)

      (trace:info "---------------- module globals: ")
      (trace:info module-globals)

      (trace:info "---------------- C code:")
      (mta:code-gen input-program 
                    program? 
                    lib-name 
                    lib-pass-thru-exports
                    imported-vars
                    module-globals
                    c-headers
                    lib-deps
                    src-file) 
      (return '())))) ;; No codes to return

;; Read top-level imports from a program and return a cons of:
;; - imports
;; - remaining program
(define (import-reduction expr expander)
  (let ((results
          (foldl
            (lambda (ex accum)
              (define (process e)
                (cond
                  ((tagged-list? 'import e)
                   (cons (cons (cdr e) (car accum)) (cdr accum)))
                  (else
                    (cons (car accum) (cons e (cdr accum))))))
              (cond
               ((tagged-list? 'cond-expand ex)
                (let ((ex* (expander ex))) ;(expand ex (macro:get-env) rename-env)))
                  ;(trace:info `(DEBUG ,ex* ,ex))
                  (if (tagged-list? 'import ex*)
                      (process ex*)
                      (process ex))))
               (else
                (process ex))))
            (cons '() '())
            expr)))
    (cons
      (apply append (reverse (car results)))
      (reverse (cdr results)))))

;; Return a function to expand any built-in macros
;; NOTE: since this uses a global macro env, it will be overridden later on when
;; macros are loaded from dependent libraries.
(define (base-expander)
  (let ((rename-env (env:extend-environment '() '() '()))
        (macros (filter 
                  (lambda (v) 
                    (Cyc-macro? (Cyc-get-cvar (cdr v))))
                  (Cyc-global-vars))))
    (macro:load-env! macros (create-environment '() '()))
    (lambda (ex) 
      (expand ex (macro:get-env) rename-env))))

;; TODO: longer-term, will be used to find where cyclone's data is installed
(define (get-data-path)
  ".")

(define (get-lib filename)
  (string-append (get-data-path) "/" filename))

(define (read-file filename)
  (call-with-input-file filename
    (lambda (port)
      (read-all port))))

;; Compile and emit:
(define (run-compiler args cc? cc-prog cc-exec cc-lib cc-so append-dirs prepend-dirs)
  (let* ((in-file (car args))
         (expander (base-expander))
         (in-prog-raw (read-file in-file))
         (program? (not (library? (car in-prog-raw))))
         (in-prog
          (if program? 
              in-prog-raw
              ;; Account for any cond-expand declarations in the library
              (list (lib:cond-expand (car in-prog-raw) expander))))
   ;; TODO: expand in-prog, if a library, using lib:cond-expand. (OK, this works now)
   ;; TODO: will also need to do below in lib:get-all-import-deps, after reading each library
         (program:imports/code (if program? (import-reduction in-prog expander) '()))
         (lib-deps 
           (if (and program?
                    (not (null? (car program:imports/code))))
             (lib:get-all-import-deps (car program:imports/code) append-dirs prepend-dirs)
            '()))
         (exec-file (basename in-file))
         (src-file (string-append exec-file ".c"))
         (meta-file (string-append exec-file ".meta"))
         (get-comp-env 
           (lambda (sym str)
             (if (> (string-length str) 0)
                 str
                 (Cyc-compilation-environment sym)))) 
         (create-c-file 
           (lambda (program) 
             (with-output-to-file 
               src-file
               (lambda ()
                 (c-compile-and-emit 
                   program 
                   program:imports/code 
                   lib-deps 
                   (lambda (new-lib-deps)
                     (set! lib-deps new-lib-deps))
                   in-file 
                   append-dirs 
                   prepend-dirs)))))
         (result (create-c-file in-prog)))

    ;; Compile the generated C file
    (cond
      (program?
        (letrec ((objs-str 
                  (apply
                    string-append
                    (map
                      (lambda (i)
                        (string-append " " (lib:import->filename i ".o" append-dirs prepend-dirs) " "))
                      lib-deps)))
                 (comp-prog-cmd 
                   (string-replace-all 
                     (string-replace-all 
                       ;(Cyc-compilation-environment 'cc-prog) 
                       (get-comp-env 'cc-prog cc-prog)
                       "~src-file~" src-file)
                     "~exec-file~" exec-file))
                 (comp-objs-cmd 
                   (string-replace-all
                     (string-replace-all
                       (string-replace-all
                         ;(Cyc-compilation-environment 'cc-exec)
                         (get-comp-env 'cc-exec cc-exec)
                         "~exec-file~" exec-file)
                       "~obj-files~" objs-str)
                     "~exec-file~" exec-file)))
          ;(write `(DEBUG all imports ,lib-deps objs ,objs-str))
          ;(write `(DEBUG ,(lib:get-all-import-deps (cdar in-prog))))
          (cond
            (cc?
             (if (equal? 0 (system comp-prog-cmd))
               (system comp-objs-cmd)))
            (else
              (display comp-prog-cmd)
              (newline)
              (display comp-objs-cmd)
              (newline)))))
      (else
        ;; Emit .meta file
        (with-output-to-file
          meta-file
          (lambda ()
            (display ";; This file was automatically generated by the Cyclone Scheme compiler")
            (newline)
            (write (macro:get-defined-macros))))
        ;; Compile library
        (let ((comp-lib-cmd
                (string-replace-all 
                  (string-replace-all 
                    (get-comp-env 'cc-lib cc-lib)
                    "~src-file~" src-file)
                  "~exec-file~" exec-file))
              (comp-so-cmd
                (string-replace-all 
                  (string-replace-all 
                    (get-comp-env 'cc-so cc-so)
                    "~src-file~" src-file)
                  "~exec-file~" exec-file))
              )
          (cond
            (cc?
              (system comp-lib-cmd)
              (system comp-so-cmd)
            )
            (else
              (display comp-lib-cmd)
              (newline)
              (display comp-so-cmd)
              (newline))))))))

;; Collect values for the given command line arguments and option.
;; Will return a list of values for the option.
;; For example:
;;  ("-a" "1" "2") ==> ("1")
;;  ("-a" "1" -a "2") ==> ("1" "2")
(define (collect-opt-values args opt)
  (cdr
    (foldl
      (lambda (arg accum)
        (cond
          ((equal? arg opt)
           (cons opt (cdr accum)))
          ((car accum) ;; we are at an opt value
           (cons #f (cons arg (cdr accum))))
          (else
           (cons #f (cdr accum)))))
      (list #f)
      args)))

;; Handle command line arguments
(let* ((args (command-line-arguments)) ;; TODO: port (command-line-arguments) to husk??
       (non-opts 
        (if (null? args)
            '()
            (list (car (reverse args)))))
                ; (filter
                ;   (lambda (arg) 
                ;     (not (and (> (string-length arg) 1)
                ;               (equal? #\- (string-ref arg 0)))))
                ;   args))
       (compile? #t)
       (cc-prog (apply string-append (collect-opt-values args "-CP")))
       (cc-exec (apply string-append (collect-opt-values args "-CE")))
       (cc-lib  (apply string-append (collect-opt-values args "-CL")))
       (cc-so   (apply string-append (collect-opt-values args "-CS")))
       (append-dirs (collect-opt-values args "-A"))
       (prepend-dirs (collect-opt-values args "-I")))
  ;; Set optimization level(s)
  (if (member "-O0" args)
      (set! *optimization-level* 0))
  ;; TODO: place more optimization reading here as necessary
  ;; End optimizations
  (if (member "-t" args)
      (set! *trace-level* 4)) ;; Show all trace output
  (if (member "-d" args)
     (set! compile? #f)) ;; Debug, do not run GCC
  (cond
    ((or (member "-h" args)
         (member "--help" args))
     (display "
Usage: cyclone [OPTIONS] FILENAME
Run the Cyclone Scheme compiler.

Options:

 -A directory    Append directory to the list of directories that are searched 
                 in order to locate imported libraries.
 -I directory    Prepend directory to the list of directories that are searched 
                 in order to locate imported libraries.
 -CP cc-commands Specify a custom command line for the C compiler to compile
                 a program module. See Makefile.config for an example of how
                 to construct such a command line.
 -CE cc-commands Specify a custom command line for the C compiler to compile
                 an executable.
 -CL cc-commands Specify a custom command line for the C compiler to compile
                 a library module.
 -CS cc-commands Specify a custom command line for the C compiler to compile
                 a shared object module.
 -Ox             Optimization level, higher means more optimizations will
                 be used. Set to 0 to disable optimizations.
 -d              Only generate intermediate C files, do not compile them
 -t              Show intermediate trace output in generated C files
 -h, --help      Display usage information
 -v              Display version information
 -vn             Display version number
")
     (newline))
    ((member "-v" args)
     (display *version-banner*))
    ((member "--autogen" args)
     (autogen "autogen.out")
     (newline))
    ((member "-v" args)
     (display *version-banner*))
    ((member "-vn" args)
     (display (Cyc-version)))
    ((member "--autogen" args)
     (autogen "autogen.out"))
    ((or (< (length args) 1)
         (null? non-opts))
     (display "cyclone: no input file")
     (newline))
    (else
      (run-compiler non-opts compile? cc-prog cc-exec cc-lib cc-so append-dirs prepend-dirs))))

