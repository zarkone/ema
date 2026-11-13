;;; ema-tools.el --- The agent's documented functions -*- lexical-binding: t -*-

;;; Commentary:

;; A "tool" here is an ordinary Emacs Lisp function with a docstring,
;; defined with `ema-deftool'.  The docstring is the only documentation:
;; the system prompt lists every tool with its first docstring line, and
;; the agent reads the rest with `describe-function' semantics
;; (`ema-doc').  The agent extends itself with `ema-tool-save', which
;; stores a new tool in `ema-directory'/tools/ so the next Emacs session
;; loads it again.  Skills are the same idea for prose: Markdown notes.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'project)
(require 'xref)
(require 'package)
(require 'imenu)
(require 'cl-lib)
(require 'diff)
(require 'vc)
(require 'grep)
(require 'eieio)

(declare-function eglot-project-nickname "eglot")

(defface ema-noted-line '((t :inherit highlight))
  "Face of a line that carries an ema review note."
  :group 'ema)
(defface ema-note-text '((t :inherit warning :slant italic))
  "Face of an ema review note."
  :group 'ema)

(declare-function eglot-current-server "eglot")
(declare-function eglot--TextDocumentPositionParams "eglot")
(declare-function jsonrpc-request "jsonrpc")
(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")

(defvar ema-directory (locate-user-emacs-file "ema/")
  "Directory for the agent's own state: tools/ and skills/.")

(defvar ema-builtin-skills-directory
  (expand-file-name "skills/" (file-name-directory
                               (or load-file-name buffer-file-name
                                   default-directory)))
  "Directory of the skills shipped with ema.")

(defvar ema-tools nil
  "Symbols defined with `ema-deftool', in definition order.")

(defmacro ema-deftool (name args doc &rest body)
  "Define function NAME with ARGS, docstring DOC and BODY as an agent tool.
DOC is mandatory: its first line goes into the tool list the model reads."
  (declare (doc-string 3) (indent defun))
  (unless (stringp doc)
    (error "ema-deftool %s: a docstring is mandatory" name))
  `(progn
     (defun ,name ,args ,doc ,@body)
     (unless (memq ',name ema-tools)
       (setq ema-tools (append ema-tools (list ',name))))
     ',name))

(defun ema-tools-index ()
  "Return the tool list as text: one signature and summary per line."
  (mapconcat
   (lambda (sym)
     (format "(%s) — %s"
             (string-join (cons (symbol-name sym)
                                (mapcar #'symbol-name (help-function-arglist sym t)))
                          " ")
             (car (split-string (or (documentation sym t) "") "\n"))))
   ema-tools "\n"))

;;;; Self-extension: stored tools

(defun ema--tools-dir ()
  (let ((dir (expand-file-name "tools/" ema-directory)))
    (make-directory dir t)
    dir))

(defun ema-load-tools ()
  "Load every stored tool from `ema-directory'/tools/."
  (dolist (file (directory-files (ema--tools-dir) t "\\.el\\'"))
    (condition-case err
        (load file nil t)
      (error (message "ema: tool %s failed to load: %s"
                      (file-name-nondirectory file)
                      (error-message-string err))))))

(ema-deftool ema-doc (symbol)
  "Return the full documentation and signature of function or variable SYMBOL.
Read it before the first call of a function you do not know."
  (cond ((fboundp symbol)
         (format "%S\n%s" (cons symbol (help-function-arglist symbol t))
                 (or (documentation symbol t) "(no docstring)")))
        ((boundp symbol)
         (format "variable %s\n%s" symbol
                 (or (documentation-property symbol 'variable-documentation t)
                     "(no docstring)")))
        (t (format "%s is not defined; try (apropos-internal \"%s\")"
                   symbol symbol))))

(ema-deftool ema-tool-save (source)
  "Define and store a new tool from string SOURCE.
SOURCE is one `(ema-deftool NAME ARGS DOC BODY...)' form.
The tool works at once and is loaded again in later Emacs sessions.
Saving a tool with an existing name replaces it.  Test the body in a
cell first; store it when it works."
  (let* ((form (read source))
         (name (and (eq (car-safe form) 'ema-deftool) (cadr form))))
    (unless (and name (symbolp name))
      (error "SOURCE must be one (ema-deftool NAME ARGS DOC BODY...) form"))
    (eval form t)
    (let ((file (expand-file-name (format "%s.el" name) (ema--tools-dir))))
      (with-temp-file file
        (insert (format ";;; %s.el --- ema tool -*- lexical-binding: t -*-\n\n" name)
                (string-trim source) "\n"))
      (format "saved %s -> %s" name file))))

(ema-deftool ema-tool-delete (name)
  "Remove stored tool NAME (a symbol): its file and its list entry."
  (let ((file (expand-file-name (format "%s.el" name) (ema--tools-dir))))
    (when (file-exists-p file) (delete-file file))
    (setq ema-tools (delq name ema-tools))
    (fmakunbound name)
    (format "deleted %s" name)))

;;;; Skills: prose notes

(defun ema--skills-dir ()
  (let ((dir (expand-file-name "skills/" ema-directory)))
    (make-directory dir t)
    dir))

(defun ema--skill-files ()
  "Alist of (NAME . FILE); the user's skills shadow the shipped ones."
  (let (out)
    (dolist (dir (list (ema--skills-dir) ema-builtin-skills-directory))
      (when (file-directory-p dir)
        (dolist (f (directory-files dir t "\\.md\\'"))
          (unless (assoc (file-name-base f) out)
            (push (cons (file-name-base f) f) out)))))
    (sort out (lambda (a b) (string< (car a) (car b))))))

(defun ema-skills-index ()
  "Return the skill list as text: name and first line."
  (mapconcat
   (lambda (cell)
     (format "%s — %s" (car cell)
             (with-temp-buffer
               (insert-file-contents (cdr cell) nil 0 300)
               (string-trim (car (split-string (buffer-string) "\n")) "[# \t]+"))))
   (seq-remove (lambda (c) (equal (car c) "core")) (ema--skill-files))
   "\n"))

(ema-deftool ema-skill (name)
  "Return the body of skill NAME (a string): a Markdown note with know-how."
  (let ((file (cdr (assoc name (ema--skill-files)))))
    (unless file (error "No skill %s; skills: %s" name
                        (mapcar #'car (ema--skill-files))))
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

(ema-deftool ema-skill-save (name text)
  "Store Markdown TEXT as skill NAME; its first line is its summary.
Use it for durable know-how: a procedure that worked, a user preference,
a fact about this machine.  It is listed in every later conversation."
  (let ((file (expand-file-name (concat name ".md") (ema--skills-dir))))
    (with-temp-file file (insert (string-trim text) "\n"))
    (format "saved skill %s -> %s" name file)))

;;;; What the user sees

(defun ema--buffer-line (buf)
  (with-current-buffer buf
    (format "%s%s  [%s]%s" (buffer-name)
            (if (buffer-modified-p) "*" "")
            major-mode
            (if buffer-file-name (concat "  " (abbreviate-file-name buffer-file-name)) ""))))

(ema-deftool ema-view ()
  "Return what the user sees now: each window of the selected frame.
For each window: buffer, mode, file, visible lines, point, the active
region.  The first window is the most recently used one that is not the
ema chat: \"this buffer\", \"here\" and \"this\" mean it."
  (let* ((wins (seq-remove
                (lambda (w) (with-current-buffer (window-buffer w)
                              (derived-mode-p 'ema-mode)))
                (window-list (selected-frame) 'no-minibuf)))
         (wins (sort wins (lambda (a b) (> (window-use-time a) (window-use-time b))))))
    (if (null wins)
        "No window besides the ema chat."
      (mapconcat
       (lambda (w)
         (with-current-buffer (window-buffer w)
           (let ((pt (window-point w)))
             (format "%s\n  lines %d-%d visible, point at line %d col %d%s%s"
                     (ema--buffer-line (current-buffer))
                     (line-number-at-pos (window-start w))
                     (line-number-at-pos (window-end w t))
                     (line-number-at-pos pt)
                     (save-excursion (goto-char pt) (current-column))
                     (if (use-region-p)
                         (format ", region lines %d-%d"
                                 (line-number-at-pos (region-beginning))
                                 (line-number-at-pos (region-end)))
                       "")
                     (let ((pr (project-current nil)))
                       (if pr (format "\n  project %s"
                                      (abbreviate-file-name (project-root pr)))
                         ""))))))
       wins "\n"))))

(ema-deftool ema-buffers (&optional regexp)
  "Return the open buffers, most recently used first, one per line.
With REGEXP, only buffers whose name or file matches.  Internal buffers
(names that start with a space) are left out."
  (mapconcat
   #'ema--buffer-line
   (seq-filter (lambda (b)
                 (and (not (string-prefix-p " " (buffer-name b)))
                      (or (null regexp)
                          (string-match-p regexp (buffer-name b))
                          (and (buffer-file-name b)
                               (string-match-p regexp (buffer-file-name b))))))
               (buffer-list))
   "\n"))

(defun ema--numbered-lines (from-line to-line)
  "Return lines FROM-LINE..TO-LINE of the current buffer with line numbers."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- (or from-line 1)))
      (let ((n (or from-line 1)) lines)
        (while (and (not (eobp)) (or (null to-line) (<= n to-line)))
          (push (format "%d\t%s" n (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position)))
                lines)
          (setq n (1+ n))
          (forward-line 1))
        (string-join (nreverse lines) "\n")))))

(ema-deftool ema-buffer-text (buffer-or-file &optional from-line to-line)
  "Return the text of BUFFER-OR-FILE with line numbers.
BUFFER-OR-FILE is a buffer name or a file path.  A file that is open is
read from its buffer, with the unsaved changes; a file that is not open
is read from disk and stays closed.  FROM-LINE and TO-LINE bound the
part; the default is the whole text.  Use this, not sed or cat."
  (let ((buf (or (get-buffer buffer-or-file)
                 (and (stringp buffer-or-file)
                      (find-buffer-visiting (expand-file-name buffer-or-file))))))
    (cond
     (buf (with-current-buffer buf (ema--numbered-lines from-line to-line)))
     ((and (stringp buffer-or-file) (file-regular-p buffer-or-file))
      (with-temp-buffer
        (insert-file-contents buffer-or-file)
        (ema--numbered-lines from-line to-line)))
     (t (error "No buffer and no file named %s" buffer-or-file)))))

;;;; Projects

(ema-deftool ema-project (&optional dir)
  "Return the project of DIR (default: the current buffer's directory).
A plist (:root :name :files N), or nil when DIR is in no project."
  (when-let* ((default-directory (or dir default-directory))
              (pr (project-current nil)))
    (list :root (project-root pr) :name (project-name pr)
          :files (length (project-files pr)))))

(ema-deftool ema-project-files (&optional regexp dir)
  "Return the files of the project of DIR, relative to its root.
With REGEXP, only the matching paths."
  (let* ((default-directory (or dir default-directory))
         (pr (or (project-current nil) (error "Not in a project: %s" default-directory)))
         (root (project-root pr))
         (files (mapcar (lambda (f) (file-relative-name f root)) (project-files pr))))
    (if regexp (seq-filter (lambda (f) (string-match-p regexp f)) files) files)))

(defcustom ema-search-max-hits 200
  "`ema-search' returns at most this many hits."
  :type 'integer :group 'ema)

(ema-deftool ema-search (regexp &optional files dir show)
  "Search the project for REGEXP; return \"file:line: text\" lines.
Use this, not grep in a shell.  REGEXP has Emacs syntax: \\\\| is the
alternation, \\\\( \\\\) group, a bare | or ( is literal.  The search covers
the project's files and honours its ignore rules; outside a project it
covers the directory tree.  FILES is a regexp on the relative path
\(\"\\\\.el\\\\'\" for example).  DIR is where to search (default: the
current directory); inside a project it limits the search to that
directory.  With SHOW non-nil the hits also open for the user in a grep
buffer, where next-error works.  At most `ema-search-max-hits' hits
come back; the last line says how many are left out."
  (let* ((default-directory (file-name-as-directory
                             (expand-file-name (or dir default-directory))))
         (pr (project-current nil))
         (root (if pr (expand-file-name (project-root pr)) default-directory))
         (keep (lambda (f) (or (null files)
                               (string-match-p files (file-relative-name f root)))))
         (items (if pr
                    (let ((paths (seq-filter keep (project-files
                                                   pr (and dir (list default-directory))))))
                      (and paths (xref-matches-in-files regexp paths)))
                  (seq-filter (lambda (x) (funcall keep (xref-location-group
                                                         (xref-item-location x))))
                              (xref-matches-in-directory regexp "*" root nil))))
         (lines (mapcar (lambda (x)
                          (let ((loc (xref-item-location x)))
                            (format "%s:%d: %s"
                                    (file-relative-name (xref-location-group loc) root)
                                    (xref-location-line loc)
                                    (string-trim (substring-no-properties (xref-item-summary x))))))
                        items))
         (total (length lines))
         (shown (seq-take lines ema-search-max-hits)))
    (when (and show lines)
      (with-current-buffer (get-buffer-create "*ema: search*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (setq default-directory root)
          (insert (format "ema search for %s in %s\n\n" regexp (abbreviate-file-name root))
                  (string-join lines "\n") "\n")
          (grep-mode)
          (goto-char (point-min)))
        (ema--side-window (current-buffer))))
    (cond ((null lines) (format "no hits in %s" (abbreviate-file-name root)))
          ((> total (length shown))
           (concat (string-join shown "\n")
                   (format "\n… %d more hits: narrow REGEXP or FILES"
                           (- total (length shown)))))
          (t (string-join shown "\n")))))

;;;; Code intelligence (LSP through eglot, xref, flymake, imenu)

(defun ema--goto-symbol (symbol line)
  "Move point onto SYMBOL (a string): on LINE when given, else its first use."
  (widen)
  (goto-char (point-min))
  (when line (forward-line (1- line)))
  (unless (re-search-forward (concat "\\_<" (regexp-quote symbol) "\\_>")
                             (and line (line-end-position)) t)
    (error "Symbol %s not found%s" symbol (if line (format " on line %d" line) "")))
  (goto-char (match-beginning 0)))

(defun ema--xref-lines (xrefs)
  (mapcar (lambda (x)
            (let* ((loc (xref-item-location x))
                   ;; some backends (elisp) know the line only once the
                   ;; location is resolved to a marker
                   (m (ignore-errors (xref-location-marker loc))))
              (format "%s:%s: %s"
                      (abbreviate-file-name
                       (or (and m (buffer-file-name (marker-buffer m)))
                           (ignore-errors (xref-location-group loc))
                           "?"))
                      (or (and m (with-current-buffer (marker-buffer m)
                                   (save-restriction
                                     (widen) (line-number-at-pos m))))
                          (ignore-errors (xref-location-line loc))
                          "?")
                      (string-trim (substring-no-properties (xref-item-summary x))))))
          xrefs))

(ema-deftool ema-xref (kind buffer symbol &optional line)
  "Find where SYMBOL (a string) in BUFFER is defined or used.
KIND is `definitions' or `references'.  The symbol is
taken at its first occurrence, or on LINE when given.  The answer comes
from the buffer's xref backend: the language server when eglot manages
the buffer, else etags or the elisp backend.  Returns \"file:line: text\" lines."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (ema--goto-symbol symbol line)
        (let* ((backend (or (xref-find-backend) (error "No xref backend here")))
               (id (xref-backend-identifier-at-point backend)))
          (ema--xref-lines
           (pcase kind
             ('definitions (xref-backend-definitions backend id))
             ('references (xref-backend-references backend id))
             (_ (error "KIND must be definitions or references")))))))))

(ema-deftool ema-lsp (buffer method symbol &optional line)
  "Send LSP request METHOD at SYMBOL in BUFFER; return the raw result.
METHOD is a keyword such as :textDocument/hover or
:textDocument/typeDefinition.  The buffer must be managed by eglot
\(start it with `eglot-ensure').  For hover, the text is under
:contents.  SYMBOL and LINE select the position as in `ema-xref'."
  (with-current-buffer buffer
    (unless (and (fboundp 'eglot-current-server) (eglot-current-server))
      (error "Buffer %s has no language server; call (eglot-ensure) in it" buffer))
    (save-excursion
      (save-restriction
        (ema--goto-symbol symbol line)
        (jsonrpc-request (eglot-current-server) method
                         (eglot--TextDocumentPositionParams))))))

(ema-deftool ema-diagnostics (&optional buffer)
  "Return the errors and warnings of BUFFER (default: current) from flymake.
With eglot these are the language server's diagnostics.  One
\"line: type: message\" string per diagnostic."
  (with-current-buffer (or buffer (current-buffer))
    (unless (bound-and-true-p flymake-mode)
      (error "flymake is not on in %s; call (flymake-mode 1)" (buffer-name)))
    (mapcar (lambda (d)
              (format "%d: %s: %s"
                      (line-number-at-pos (flymake-diagnostic-beg d))
                      (flymake-diagnostic-type d)
                      (flymake-diagnostic-text d)))
            (flymake-diagnostics))))

(ema-deftool ema-outline (&optional buffer)
  "Return the definitions in BUFFER (default: current) from imenu, as \"line: name\"."
  (with-current-buffer (or buffer (current-buffer))
    (let (out)
      (cl-labels ((walk (items prefix)
                    (dolist (it items)
                      (cond ((imenu--subalist-p it)
                             (walk (cdr it) (concat prefix (car it) "/")))
                            ((and (consp it) (not (equal (car it) "*Rescan*")))
                             (let ((pos (cdr it)))
                               (push (format "%s: %s%s"
                                             (cond ((markerp pos) (line-number-at-pos pos))
                                                   ((integerp pos) (line-number-at-pos pos))
                                                   ((overlayp pos) (line-number-at-pos (overlay-start pos)))
                                                   (t "?"))
                                             prefix (car it))
                                     out)))))))
        (walk (let ((imenu-auto-rescan t)) (imenu--make-index-alist t)) ""))
      (nreverse out))))

;;;; Working in front of the user: show, edit, present, ask

(defun ema--side-window (buffer)
  "Display BUFFER in a window that is not the ema chat; return the window."
  (display-buffer buffer
                  '((display-buffer-reuse-window
                     display-buffer-use-some-window
                     display-buffer-pop-up-window)
                    (inhibit-same-window . t)
                    (some-window . mru))))

(defvar ema--mark-pushed nil
  "Non-nil when this turn already saved the user's position for \\[xref-go-back].")

(defun ema--push-mark ()
  "Save the user's position once a turn, so that \\[xref-go-back] returns there."
  (unless ema--mark-pushed
    (let ((win (seq-find (lambda (w) (not (string-prefix-p "*ema" (buffer-name (window-buffer w)))))
                         (sort (window-list nil 'no-minibuf)
                               (lambda (a b) (> (window-use-time a) (window-use-time b)))))))
      (when win
        (setq ema--mark-pushed t)
        (ignore-errors
          (xref-push-marker-stack
           (with-current-buffer (window-buffer win)
             (copy-marker (window-point win)))))))))

(defvar ema--change-groups nil
  "Alist (BUFFER . HANDLE): the buffers that ema edited in this turn.")

(defun ema--open-change-group ()
  "Start an undo group for this turn in the current buffer, once."
  (unless (or (assq (current-buffer) ema--change-groups) (eq buffer-undo-list t))
    (let ((handle (prepare-change-group)))
      (activate-change-group handle)
      (push (cons (current-buffer) handle) ema--change-groups))))

(defun ema--close-change-groups ()
  "Make the edits of this turn one undo step in each buffer; end the turn's marks."
  (dolist (cell ema--change-groups)
    (when (buffer-live-p (car cell))
      (ignore-errors
        (undo-amalgamate-change-group (cdr cell))
        (accept-change-group (cdr cell)))))
  (setq ema--change-groups nil
        ema--mark-pushed nil))

(defun ema--pulse (beg end)
  (when (fboundp 'pulse-momentary-highlight-region)
    (ignore-errors (pulse-momentary-highlight-region beg end))))

(ema-deftool ema-show (buffer-or-file &optional line end-line)
  "Show BUFFER-OR-FILE to the user in a window beside the chat.
With LINE, scroll there and highlight LINE to END-LINE.  Use it to point
at the code you talk about.  Returns the buffer name."
  (let* ((buf (if (and (stringp buffer-or-file) (not (get-buffer buffer-or-file)))
                  (find-file-noselect buffer-or-file)
                (get-buffer buffer-or-file)))
         (win (progn (ema--push-mark) (ema--side-window buf))))
    (when line
      (with-selected-window win
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter (min 5 (/ (window-height) 4)))
        (ema--pulse (line-beginning-position)
                    (save-excursion
                      (forward-line (- (or end-line line) line))
                      (line-end-position)))))
    (buffer-name buf)))

(ema-deftool ema-edit (file old new &optional save)
  "In FILE, replace the one occurrence of string OLD with NEW; show the change.
OLD must occur exactly once: include enough context lines.  The edit is
made in the file's buffer, shown beside the chat and highlighted.  All
edits of one turn in a buffer are one undo step for the user.  With SAVE
non-nil the buffer is saved, which tools that read the disk (compilers,
the language server) need.  An empty OLD
with a new FILE creates the file."
  (let ((buf (find-file-noselect file)))
    (ema--push-mark)
    (with-current-buffer buf
      (ema--open-change-group)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (let ((count (if (string-empty-p old)
                           (if (= (buffer-size) 0) 1
                             (error "Empty OLD is only for a new, empty file"))
                         (how-many (regexp-quote old)))))
            (unless (= count 1)
              (error "OLD occurs %d times in %s; it must occur once" count file))
            (unless (string-empty-p old)
              (search-forward old)
              (delete-region (match-beginning 0) (match-end 0)))
            (let ((beg (point)))
              (insert new)
              (let ((end (point)) (line (line-number-at-pos beg)))
                (when save (save-buffer))
                (let ((win (ema--side-window buf)))
                  (with-selected-window win
                    (goto-char beg)
                    (recenter (min 5 (/ (window-height) 4)))
                    (ema--pulse beg end)))
                (format "edited %s at line %d%s" (abbreviate-file-name file) line
                        (if save "" " (not saved)"))))))))))

(ema-deftool ema-present (name text &optional mode)
  "Show TEXT to the user in a temporary buffer *ema: NAME* beside the chat.
Use it for anything long or structured: a report, a table, a diff, a
draft.  MODE is a major mode function, such as `org-mode', `diff-mode'
or `markdown-mode'.  The same NAME replaces the earlier content."
  (let ((buf (get-buffer-create (format "*ema: %s*" name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (when (and mode (fboundp mode)) (funcall mode))
        (set-buffer-modified-p nil)))
    (ema--side-window buf)
    (buffer-name buf)))

(ema-deftool ema-choose (prompt choices &optional multiple)
  "Ask the user to pick one of CHOICES (strings) in the minibuffer; return it.
PROMPT is the question.  With MULTIPLE non-nil the user can pick several
and a list comes back.  The user can also type an answer that is not in
the list.  Use it when you need a decision, not for a yes or no."
  (let ((prompt (concat (string-trim-right prompt "[: ]+") ": ")))
    (if multiple
        (completing-read-multiple prompt choices)
      (completing-read prompt choices))))

(ema-deftool ema-confirm (question)
  "Ask the user yes-or-no QUESTION in the minibuffer; return t or nil.
Use it before an action that is hard to undo."
  (y-or-n-p (concat (string-trim-right question "[? ]+") "? ")))

;;;; Review: notes on lines, changes the user accepts

(declare-function flymake-make-diagnostic "flymake")
(declare-function flymake-start "flymake")
(defvar flymake-diagnostic-functions)

(defun ema--note-overlays ()
  "Return the note overlays of the current buffer, in buffer order."
  (save-restriction
    (widen)
    (sort (seq-filter (lambda (ov) (overlay-get ov 'ema-note))
                      (overlays-in (point-min) (point-max)))
          (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(defun ema-flymake (report-fn &rest _)
  "A flymake backend: report the ema review notes as diagnostics."
  (funcall report-fn
           (mapcar (lambda (ov)
                     (flymake-make-diagnostic
                      (current-buffer) (overlay-start ov) (overlay-end ov)
                      :note (concat "ema: " (overlay-get ov 'ema-note))))
                   (ema--note-overlays))))

(defun ema--notes-changed ()
  "Tell flymake, when it is on here, that the notes changed."
  (when (bound-and-true-p flymake-mode)
    (add-hook 'flymake-diagnostic-functions #'ema-flymake nil t)
    (ignore-errors (flymake-start))))

(ema-deftool ema-note (buffer line text)
  "Attach review note TEXT to LINE of BUFFER, shown under that line.
The note is an overlay: it does not change the file.  Use it to review
code in place: one short note per finding, then a summary in the chat.
Where flymake is on, the note is also a diagnostic, so the user's usual
keys and lists reach it.  The user moves between notes with
\\[ema-next-note] and \\[ema-previous-note] and removes them with \\[ema-clear-notes]."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (1- line))
        (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
          (overlay-put ov 'ema-note text)
          (overlay-put ov 'face 'ema-noted-line)
          (overlay-put ov 'after-string
                       (propertize (concat "\n  ▸ " (string-replace "\n" "\n    " text))
                                   'face 'ema-note-text))
          (overlay-put ov 'evaporate t))))
    (ema--notes-changed)
    (ema--push-mark)
    (ema--side-window (current-buffer))
    (format "note on %s:%d" (buffer-name) line)))

(ema-deftool ema-notes (&optional buffer)
  "Return the review notes in BUFFER (default: current) as \"line: text\"."
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (mapcar (lambda (ov)
                (format "%d: %s" (line-number-at-pos (overlay-start ov))
                        (overlay-get ov 'ema-note)))
              (ema--note-overlays)))))

(defun ema-clear-notes (&optional buffer)
  "Remove the ema review notes from BUFFER (default: the current buffer)."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'face 'ema-noted-line))
    (ema--notes-changed)))

(defun ema-next-note (&optional backward)
  "Move to the next ema review note; with BACKWARD, to the previous one."
  (interactive "P")
  (let* ((starts (mapcar #'overlay-start (ema--note-overlays)))
         (to (if backward
                 (car (last (seq-filter (lambda (p) (< p (line-beginning-position))) starts)))
               (seq-find (lambda (p) (> p (line-end-position))) starts))))
    (unless starts (user-error "No ema notes in this buffer"))
    (goto-char (or to (if backward (car (last starts)) (car starts))))
    (message "%s" (overlay-get (seq-find (lambda (ov) (overlay-get ov 'ema-note))
                                         (overlays-at (point)))
                               'ema-note))))

(defun ema-previous-note ()
  "Move to the previous ema review note."
  (interactive)
  (ema-next-note t))

(ema-deftool ema-suggest (file old new &optional why)
  "Propose to replace OLD with NEW in FILE; the user accepts or declines.
The change is shown as a diff beside the chat with the reason WHY, and
the user answers in the minibuffer.  Returns \"applied\" or \"declined\".
This is the default way to change the user's code: they stay the
author.  OLD must occur exactly once (see `ema-edit')."
  (let* ((buf (find-file-noselect file))
         (after (generate-new-buffer " *ema-after*"))
         (diff (get-buffer-create "*ema: suggestion*")))
    (unwind-protect
        (progn
          (with-current-buffer after
            (insert (with-current-buffer buf
                      (save-restriction (widen) (buffer-string))))
            (goto-char (point-min))
            (unless (= 1 (how-many (regexp-quote old)))
              (error "OLD occurs %d times in %s; it must occur once"
                     (how-many (regexp-quote old)) file))
            (search-forward old)
            (replace-match new t t))
          (diff-no-select buf after "-u" t diff)
          (ema--side-window diff)
          (if (y-or-n-p (format "ema suggests%s. Apply? "
                                (if why (concat ": " (string-trim-right why "[. ]+")) " a change")))
              (progn (ema-edit file old new) "applied (not saved)")
            "declined"))
      (kill-buffer after))))

;;;; Status: read Emacs's, report your own

(defvar ema-status-text nil
  "What the agent says it is doing; shown in the chat header.")

(ema-deftool ema-status (text)
  "Tell the user what you are doing now: TEXT appears in the chat header.
Use it before a slow step.  It is cleared when your turn ends."
  (setq ema-status-text text)
  (force-mode-line-update t)
  (redisplay)
  text)

(ema-deftool ema-state (&optional buffer)
  "Return the status of BUFFER (default: current) as Emacs shows it.
A plist: :modified, :vc (branch and state), :diagnostics (flymake
counts), :lsp (the eglot server), :minor-modes, :compiling (running
compilations), :mode-line (the mode line text the user sees)."
  (with-current-buffer (or buffer (current-buffer))
    (list :modified (buffer-modified-p)
          :vc (and buffer-file-name
                   (ignore-errors
                     (let ((backend (vc-backend buffer-file-name)))
                       (and backend
                            (format "%s %s %s" backend
                                    (string-trim (substring-no-properties (or vc-mode "")))
                                    (vc-state buffer-file-name))))))
          :diagnostics (and (bound-and-true-p flymake-mode)
                            (let ((counts nil))
                              (dolist (d (flymake-diagnostics))
                                (cl-incf (alist-get (flymake-diagnostic-type d) counts 0)))
                              counts))
          :lsp (and (fboundp 'eglot-current-server)
                    (when-let* ((server (eglot-current-server)))
                      (format "%s" (eglot-project-nickname server))))
          :minor-modes (mapcar #'symbol-name local-minor-modes)
          :compiling (and (boundp 'compilation-in-progress)
                          (mapcar #'process-name compilation-in-progress))
          :mode-line (string-trim
                      (substring-no-properties (format-mode-line mode-line-format))))))

;;;; Packages

(ema-deftool ema-packages (&optional regexp)
  "Return the installed packages as \"name version — summary\", one per line.
With REGEXP, only packages whose name or summary matches.  A trailing
[loaded] means the feature is in use now.  Check here before you assume
that a package exists, and prefer what the user already has."
  (let (out)
    (dolist (cell package-alist)
      (let* ((desc (cadr cell))
             (line (format "%s %s — %s%s" (car cell)
                           (package-version-join (package-desc-version desc))
                           (or (package-desc-summary desc) "")
                           (if (featurep (car cell)) " [loaded]" ""))))
        (when (or (null regexp) (string-match-p regexp line))
          (push line out))))
    (string-join (sort out #'string<) "\n")))

(ema-deftool ema-package-search (regexp)
  "Search the package archives for REGEXP in the name or summary.
Returns up to 40 \"name version — summary\" lines; [installed] marks
what the user has.  Use it to find a package to suggest."
  (unless package-archive-contents (package-refresh-contents))
  (let (out)
    (dolist (cell package-archive-contents)
      (let* ((desc (cadr cell))
             (line (format "%s %s — %s%s" (car cell)
                           (package-version-join (package-desc-version desc))
                           (or (package-desc-summary desc) "")
                           (if (package-installed-p (car cell)) " [installed]" ""))))
        (when (string-match-p regexp line) (push line out))))
    (string-join (seq-take (sort out #'string<) 40) "\n")))

;;;; The system around Emacs

(defcustom ema-shell-timeout 10
  "Seconds after which `ema-shell' stops a command.
Emacs is frozen while `ema-shell' runs; long commands belong in `ema-run'."
  :type 'number :group 'ema)

(ema-deftool ema-shell (command &optional dir timeout)
  "Run a quick shell COMMAND in DIR (default: the current directory).
Returns (:exit CODE :output STRING); stderr is part of the output.
Emacs is frozen until the command ends, so it is stopped after TIMEOUT
seconds (default `ema-shell-timeout').  Not for: text search
\(`ema-search'), reading files (`ema-buffer-text'), git (`ema-git'),
builds, tests, linters and downloads (`ema-run')."
  (let* ((default-directory (file-name-as-directory
                             (expand-file-name (or dir default-directory))))
         (limit (or timeout ema-shell-timeout))
         (start (float-time)))
    (with-temp-buffer
      (let ((proc (make-process
                   :name "ema-shell" :buffer (current-buffer)
                   :command (list shell-file-name shell-command-switch command)
                   :connection-type 'pipe :noquery t :file-handler t
                   :sentinel #'ignore)))
        (unwind-protect
            (progn
              (ignore-errors (process-send-eof proc))
              (while (and (process-live-p proc)
                          (< (- (float-time) start) limit))
                (accept-process-output proc 0.1))
              (when (process-live-p proc)
                (delete-process proc)
                (error "The command ran longer than %s s and was stopped. Start it with (ema-run COMMAND) and read (ema-run-result) later"
                       limit))
              (accept-process-output proc 0.05)
              (list :exit (process-exit-status proc) :output (buffer-string)))
          (when (process-live-p proc) (delete-process proc)))))))

(defvar-local ema--run-status nil
  "In an ema-run buffer: how the command ended, or nil while it runs.")

(defun ema--run-buffer-name (name)
  (format "*ema-run: %s*" (or name "check")))

(ema-deftool ema-run (command &optional dir name)
  "Start COMMAND in DIR in the background, in a compilation buffer.
For a build, tests, a linter, a download: anything that can take more
than a moment.  Emacs stays free and the user gets the usual buffer,
where next-error jumps to each error.  NAME (default \"check\") names
the buffer; use distinct names to run several commands at once.  This
returns at once: read the outcome with `(ema-run-result NAME WAIT)`."
  (require 'compile)
  (let* ((default-directory (file-name-as-directory
                             (expand-file-name (or dir default-directory))))
         (bufname (ema--run-buffer-name name))
         (old (get-buffer bufname)))
    (when (and old (get-buffer-process old))
      (error "%s still runs; read (ema-run-result) or pass another NAME" bufname))
    (let ((buf (compilation-start command nil (lambda (_mode) bufname))))
      (with-current-buffer buf
        (setq ema--run-status nil)
        (add-hook 'compilation-finish-functions
                  (lambda (b msg)
                    (with-current-buffer b (setq ema--run-status (string-trim msg))))
                  nil t))
      (format "started in %s" bufname))))

(ema-deftool ema-run-result (&optional name wait)
  "Return (:status S :output TEXT) of the command started with `ema-run'.
S is \"running\", \"finished\" or \"exited abnormally with code N\".
NAME is the name given to `ema-run'.  WAIT is the number of seconds to
wait for the end (at most 30); the wait stops when the user types.  When
the command still runs, do other work or end your turn and say so."
  (let ((buf (or (get-buffer (ema--run-buffer-name name))
                 (error "No run named %s" (or name "check"))))
        (start (float-time)))
    (when wait
      (while (and (get-buffer-process buf)
                  (< (- (float-time) start) (min wait 30))
                  (not (input-pending-p)))
        (accept-process-output (get-buffer-process buf) 0.2)))
    (with-current-buffer buf
      (list :status (or ema--run-status
                        (if (get-buffer-process buf) "running" "unknown"))
            :output (buffer-substring-no-properties (point-min) (point-max))))))

;;;; Git: through magit when the user has it

(declare-function magit-call-git "magit-process")
(declare-function magit-process-buffer "magit-process")
(declare-function magit-toplevel "magit-git")
(declare-function magit-refresh "magit-mode")
(defvar magit-root-section)

(defconst ema--git-read-commands
  '("status" "log" "diff" "show" "blame" "grep" "ls-files" "ls-tree"
    "rev-parse" "rev-list" "describe" "shortlog" "cat-file" "merge-base"
    "name-rev" "for-each-ref" "whatchanged")
  "Git subcommands that only read; `ema-git' runs them without magit.")

(defun ema--git-plain (args)
  (with-temp-buffer
    (let ((code (apply #'process-file "git" nil t nil args)))
      (list :exit code :output (buffer-string) :via 'git))))

(defun ema--git-magit (args)
  "Run git ARGS through magit: logged in its process buffer, then a refresh."
  (let* ((code (apply #'magit-call-git args))
         (out (ignore-errors
                (with-current-buffer (magit-process-buffer t)
                  (with-no-warnings     ; magit's section slots
                    (let ((section (car (last (eieio-oref magit-root-section 'children)))))
                      (buffer-substring-no-properties
                       (eieio-oref section 'content) (eieio-oref section 'end))))))))
    (ignore-errors (magit-refresh))
    (list :exit code :output (or out "") :via 'magit)))

(ema-deftool ema-git (&rest args)
  "Run git with ARGS (strings) in the current directory; use it for all git.
Returns (:exit CODE :output STRING :via magit-or-git).  A command that
changes the repository (add, commit, checkout, stash, …) goes through
magit when the user has it: it appears in the magit process buffer and
the magit buffers refresh.  A read (status, log, diff, show, …) and a
session without magit use plain git.  For another repository bind
`default-directory' around the call.  To show the user the state, use
the magit commands themselves (`magit-status', `magit-diff-…', `magit-log-…').
Example: (ema-git \"commit\" \"-m\" \"Fix the parser\" \"parse.el\")"
  (unless (and args (seq-every-p #'stringp args))
    (error "ARGS must be strings: (ema-git \"log\" \"--oneline\" \"-5\")"))
  (if (and (not (member (car args) ema--git-read-commands))
           (or (featurep 'magit) (require 'magit nil t))
           (ignore-errors (magit-toplevel)))
      (ema--git-magit args)
    (ema--git-plain args)))

(ema-deftool ema-install (package &optional why)
  "Ask the user, then install Emacs PACKAGE (a symbol) from the archives.
WHY is one line on what the package gives them; it is part of the
question.  Returns the installed version, or \"declined\".  The feature
still needs a `require'."
  (cond
   ((package-installed-p package)
    (format "%s is already installed" package))
   ((not (y-or-n-p (format "ema wants to install %s%s. Install? " package
                           (if why (concat " (" (string-trim-right why "[. ]+") ")") ""))))
    "declined")
   (t
    (unless (assq package package-archive-contents)
      (package-refresh-contents))
    (package-install package)
    (format "%s %s installed" package
            (package-version-join
             (package-desc-version (cadr (assq package package-alist))))))))

(provide 'ema-tools)
;;; ema-tools.el ends here
