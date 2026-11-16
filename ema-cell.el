;;; ema-cell.el --- The one tool: an Emacs Lisp cell -*- lexical-binding: t -*-

;;; Commentary:

;; The model has one tool, `eval'.  A call of it is a CELL: a string of
;; Emacs Lisp that runs in the user's live Emacs.  `ema-eval-cell' runs
;; a cell and returns its DIGEST, the text that goes back to the model:
;;
;;   output:      what the cell printed
;;   messages:    the new lines of *Messages*
;;   => VALUE     the value of the last form
;;   error: …     in place of the value, when the cell failed
;;
;; A long part is cut, and the whole object is stored for `ema-value'.
;; A cell never signals: an error or a C-g comes back as text.
;;
;; This file knows nothing of the chat.  ema.el decides when a cell runs
;; and what happens with its digest.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'ema-tools)

(defcustom ema-digest-limit 4000
  "Characters of a cell result shown to the model before it is stubbed."
  :type 'integer :group 'ema)

(defcustom ema-digest-full-limit 30000
  "The limit for a cell that sets full_output."
  :type 'integer :group 'ema)

(defconst ema--tool
  '(:name "eval"
    :description "Evaluate Emacs Lisp in the user's live Emacs. All forms in `code` run in order; the result shows printed output, new *Messages* lines and the value of the last form. State persists: Emacs is the kernel. A long value is cut and stored; the result names the (ema-value N) call that returns it whole. Reply with text only, no tool call, to end the turn."
    :input_schema
    (:type "object"
     :properties
     (:code (:type "string"
             :description "Emacs Lisp source: one or more top-level forms.")
      :full_output (:type "boolean"
                    :description "Show long results whole, up to about 30k characters. For text you mean to read in full: a docstring, a skill, a file part."))
     :required ["code"]))
  "The definition of the one tool, in the neutral shape.")

;;;; Long values: cut for the model, kept for `ema-value'

(defvar ema-values (make-hash-table)
  "Large cell values, by number; read one with `ema-value'.")

(defvar ema--value-seq 0
  "The number of the latest stored value.")

(defcustom ema-values-kept 200
  "How many of the latest large cell values stay readable with `ema-value'."
  :type 'integer :group 'ema)

(defun ema-value (n)
  "Return stored value N whole: the live object, not its printed form.
A cell result that is too long ends with the N to pass here."
  (gethash n ema-values))

(defun ema--stub (text object limit)
  "Return TEXT, cut at LIMIT with a pointer to the stored OBJECT."
  (if (<= (length text) limit)
      text
    (let ((n (cl-incf ema--value-seq)))
      (puthash n object ema-values)
      (remhash (- n ema-values-kept) ema-values)
      (format "%s\n… [%d of %d chars shown. (ema-value %d) returns the whole value: slice or search it, never re-run the call that made it]"
              (substring text 0 limit) limit (length text) n))))

;;;; Errors: what a failed cell teaches the model

(defun ema--failed-tool ()
  "Return the innermost tool on the Lisp stack, or nil.
Call it from an error handler that runs before the stack unwinds."
  (catch 'found
    (mapbacktrace (lambda (_evald fn &rest _)
                    (when (and fn (symbolp fn) (memq fn ema-tools))
                      (throw 'found fn))))
    nil))

(defun ema--call-watching (body note)
  "Call BODY; when it signals an error, first call NOTE with the failed tool.
Without `handler-bind-1' (before Emacs 30) NOTE is never called."
  (if (fboundp 'handler-bind-1)
      (handler-bind-1 body '(error)
                      (lambda (_err) (funcall note (ema--failed-tool))))
    (funcall body)))

(defun ema--error-hint (err &optional tool)
  "Return a hint for error ERR, or an empty string.
TOOL is the tool in which the error came up.  The prompt names most
tools without their signature, so a failed call shows the model what
it did not read: the whole documentation after a wrong call, one line
otherwise."
  (concat
   (pcase err
     (`(void-function ,sym)
      (let ((near (apropos-internal (regexp-quote (symbol-name sym)) #'fboundp)))
        (if near (format "\nDefined functions with a similar name: %s"
                         (seq-take near 12))
          "")))
     (`(void-variable ,sym)
      (format "\n%s is not bound. A variable set in an earlier cell persists only when it was set with setq or defvar, not let." sym))
     (_ ""))
   (cond ((null tool) "")
         ((memq (car err) '(wrong-number-of-arguments wrong-type-argument
                            args-out-of-range))
          (format "\nThe documentation of %s:\n%s" tool (ema-doc tool)))
         (t (format "\nThe failed tool: %s" (ema--tool-line tool))))))

(defvar ema--cell-failed nil
  "Non-nil when the latest cell failed or was stopped.
`ema-eval-cell' sets it.  The digest cannot tell: a cell that prints
\"error: \" looks the same as one that failed.")

;;;; Run a cell

(defun ema--read-all (code)
  "Read every form in string CODE; return them inside one `progn'."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (let (forms)
      (while (progn (forward-comment (point-max)) (not (eobp)))
        (push (read (current-buffer)) forms))
      (cons 'progn (nreverse forms)))))

(defun ema--value-text (value)
  "Return VALUE as the model reads it: a string as it is, else pretty-printed."
  (if (stringp value) value (string-trim-right (pp-to-string value))))

(defun ema--digest (printed messages value failure limit)
  "Build the digest of a cell; each part is cut at LIMIT.
PRINTED is what the cell printed, MESSAGES the new *Messages* lines.
FAILURE is the text of an error or a quit; it replaces VALUE."
  (concat
   (unless (string-empty-p printed)
     (concat "output:\n" (ema--stub printed printed limit) "\n"))
   (unless (string-empty-p messages)
     (concat "messages:\n" (ema--stub messages messages limit) "\n"))
   (or failure
       (concat "=> " (ema--stub (ema--value-text value) value limit)))))

(defun ema-eval-cell (code &optional full buffer)
  "Evaluate string CODE in BUFFER's context; return the digest for the model.
The digest holds what the cell printed, new *Messages* lines and the
value of the last form, each cut at the digest limit (`ema-digest-limit',
or the larger one when FULL is non-nil).  An error or a C-g comes back
as text: a cell never signals; `ema--cell-failed' tells which it was."
  (let ((limit (if full ema-digest-full-limit ema-digest-limit))
        (out (generate-new-buffer " *ema-out*"))
        (messages-start (with-current-buffer (messages-buffer) (point-max-marker)))
        (value nil) (failure nil) (failed-tool nil))
    (unwind-protect
        (progn
          (condition-case err
              (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
                (let ((standard-output out)
                      (inhibit-quit nil)
                      (form (ema--read-all code)))
                  (setq value (ema--call-watching
                               (lambda () (eval form t))
                               (lambda (tool) (setq failed-tool tool))))))
            (quit (setq failure "Quit: the user stopped this cell with C-g."))
            (error (setq failure (concat "error: " (error-message-string err)
                                         (ema--error-hint err failed-tool)))))
          (setq ema--cell-failed (and failure t))
          (ema--digest (with-current-buffer out (buffer-string))
                       (with-current-buffer (messages-buffer)
                         (string-trim (buffer-substring-no-properties
                                       messages-start (point-max))))
                       value failure limit))
      (kill-buffer out)
      (set-marker messages-start nil))))

(provide 'ema-cell)
;;; ema-cell.el ends here
