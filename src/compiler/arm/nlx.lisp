;;;; the ARM definitions of VOPs used for non-local exit (throw,
;;;; lexical exit, etc.)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;; Make an environment-live stack TN for saving the SP for NLX entry.
(defun make-nlx-sp-tn (env)
  (physenv-live-tn
   (make-representation-tn *fixnum-primitive-type* immediate-arg-scn)
   env))

;;; Make a TN for the argument count passing location for a
;;; non-local entry.
(defun make-nlx-entry-arg-start-location ()
  (make-wired-tn *fixnum-primitive-type* immediate-arg-scn ocfp-offset))

;;; Save and restore dynamic environment.
;;;
;;; These VOPs are used in the reentered function to restore the appropriate
;;; dynamic environment.  Currently we only save the Current-Catch and binding
;;; stack pointer.  We don't need to save/restore the current unwind-protect,
;;; since unwind-protects are implicitly processed during unwinding.  If there
;;; were any additional stacks, then this would be the place to restore the top
;;; pointers.

(define-vop (save-dynamic-state)
  (:results (catch :scs (descriptor-reg))
            (nfp :scs (descriptor-reg))
            (nsp :scs (descriptor-reg)))
  (:vop-var vop)
  (:generator 13
    (load-symbol-value catch *current-catch-block*)
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (move nfp cur-nfp)))
    (load-symbol-value nsp *number-stack-pointer*)))

(define-vop (restore-dynamic-state)
  (:args (catch :scs (descriptor-reg))
         (nfp :scs (descriptor-reg))
         (nsp :scs (descriptor-reg)))
  (:vop-var vop)
  (:generator 10
    (store-symbol-value catch *current-catch-block*)
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (move cur-nfp nfp)))
    (store-symbol-value nsp *number-stack-pointer*)))

(define-vop (current-stack-pointer)
  (:results (res :scs (any-reg descriptor-reg)))
  (:generator 1
    (move res sp-tn)))

(define-vop (current-binding-pointer)
  (:results (res :scs (any-reg descriptor-reg)))
  (:generator 1
    (load-symbol-value res *binding-stack-pointer*)))

;;;; Unwind block hackery:

;;; Like Make-Unwind-Block, except that we also store in the specified tag, and
;;; link the block into the Current-Catch list.
;;;
(define-vop (make-catch-block)
  (:args (tn) (tag :scs (any-reg descriptor-reg)))
  (:info entry-label)
  (:results (block :scs (any-reg)))
  (:temporary (:scs (descriptor-reg)) temp)
  (:temporary (:scs (descriptor-reg) :target block :to (:result 0)) result)
  (:generator 44
    (inst add result fp-tn (* (tn-offset tn) n-word-bytes))
    (load-symbol-value temp *current-unwind-protect-block*)
    (storew temp result catch-block-current-uwp-slot)
    (storew fp-tn result catch-block-current-cont-slot)
    (storew code-tn result catch-block-current-code-slot)
    (inst compute-lra temp entry-label)
    (storew temp result catch-block-entry-pc-slot)

    (storew tag result catch-block-tag-slot)
    (load-symbol-value temp *current-catch-block*)
    (storew temp result catch-block-previous-catch-slot)
    (store-symbol-value result *current-catch-block*)

    (move block result)))

(define-vop (unlink-catch-block)
  (:temporary (:scs (any-reg)) block)
  (:policy :fast-safe)
  (:translate %catch-breakup)
  (:generator 17
    (load-symbol-value block *current-catch-block*)
    (loadw block block catch-block-previous-catch-slot)
    (store-symbol-value block *current-catch-block*)))

;;;; NLX entry VOPs:

(define-vop (nlx-entry)
  (:args (sp) ; Note: we can't list an sc-restriction, 'cause any load vops
              ; would be inserted before the LRA.
         (start)
         (count))
  (:results (values :more t))
  (:temporary (:scs (descriptor-reg)) move-temp)
  (:info label nvals)
  (:save-p :force-to-stack)
  (:vop-var vop)
  (:generator 30
    (emit-return-pc label)
    (note-this-location vop :non-local-entry)
    (cond ((zerop nvals))
          ((= nvals 1)
           (inst cmp count 0)
           (move (tn-ref-tn values) null-tn :eq)
           (loadw (tn-ref-tn values) start 0 0 :ne))
          (t
           (do ((i 0 (1+ i))
                (tn-ref values (tn-ref-across tn-ref)))
               ((null tn-ref))
             (let ((tn (tn-ref-tn tn-ref)))
               (inst subs count count (fixnumize 1))
               (sc-case tn
                 ((descriptor-reg any-reg)
                  (loadw tn start i 0 :ge)
                  (move tn null-tn :lt))
                 (control-stack
                  (loadw move-temp start i 0 :ge)
                  (store-stack-tn tn move-temp :ge)
                  (store-stack-tn tn null-tn :lt)))))))
    (load-stack-tn sp-tn sp)))