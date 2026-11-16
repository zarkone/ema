;;; ema-actions.el --- Send the region or the point to ema -*- lexical-binding: t -*-

;;; Commentary:

;; The DWIM entry points.  From any buffer:
;;
;;   ema-ask-here   ask about the region, or the line at point
;;   ema-add-here   put a reference to it into the chat input and go there
;;   ema-act        pick a named action from a list
;;   ema-act-NAME   one command per action (explain, review, refactor, …)
;;
;; An ACTION is a pre-prompt plus a scope.  It sends the code under the
;; cursor with its prompt in one key press.  Actions are data, kept in
;; `ema-actions' and saved in actions.eld, so the agent adds new ones
;; for the user with `ema-action-save'.
;;
;; Bind the prefix map once, for example:
;;
;;   (keymap-global-set "C-c e" ema-command-map)
;;
;; The file, top to bottom:
;;
;;   Context          what the cursor points at, as text for the model
;;   Entry points     ask here, add a reference, ask about a file
;;   Actions          the table, the prefix keymap, a command per action
;;   The menu (transient) and embark
;;   Actions: the shortcuts of the user   the tools that save an action

;;; Code:

(require 'ema)

(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")

(defcustom ema-context-max-lines 200
  "A context longer than this is sent as a reference without its text."
  :type 'integer :group 'ema)

;;;; Context: what the cursor points at

(declare-function magit-current-section "magit-section")
(declare-function dired-get-marked-files "dired")
(declare-function org-back-to-heading "org")
(declare-function org-end-of-subtree "org")
(declare-function org-get-heading "org")
(declare-function compile-goto-error "compile")

(defvar ema-context-functions
  '(ema-context-magit ema-context-dired ema-context-compilation ema-context-org)
  "Functions that build the context in buffers that are not plain code.
Each is called with SCOPE in the user's buffer, with no active region,
and returns nil or a plist (:label SHORT-REFERENCE :text BLOCK).  BLOCK
starts with a \"[context: …]\" line.  The first non-nil result is the
context; when all return nil, `ema-context' sends lines of the buffer.
Add a function here to teach ema what \"this\" means in a new mode.")

(defun ema--context-block (kind details body)
  "Return a context text: a header of KIND and DETAILS, then BODY, capped."
  (let* ((lines (split-string body "\n"))
         (n (length lines)))
    (concat (format "[context: %s | %s]\n" kind details)
            (if (> n ema-context-max-lines)
                (concat (string-join (seq-take lines ema-context-max-lines) "\n")
                        (format "\n… (%d more lines)" (- n ema-context-max-lines)))
              body))))

(defun ema-context-magit (_scope)
  "In a magit buffer: the section at point (a hunk, a file, a commit)."
  (when (and (derived-mode-p 'magit-mode) (fboundp 'magit-current-section))
    (let ((section (magit-current-section)))
      (when section
        (with-no-warnings               ; magit's section slots
          (let ((type (eieio-oref section 'type))
                (value (eieio-oref section 'value)))
            (list :label (format "magit:%s" type)
                  :text (ema--context-block
                         (format "magit %s" type)
                         (format "repository %s | buffer %s%s"
                                 (abbreviate-file-name default-directory) (buffer-name)
                                 (if (stringp value) (concat " | " value) ""))
                         (string-trim-right
                          (buffer-substring-no-properties
                           (eieio-oref section 'start) (eieio-oref section 'end)))))))))))

(defun ema-context-dired (_scope)
  "In dired: the marked files, or the file at point."
  (when (derived-mode-p 'dired-mode)
    (let ((files (ignore-errors (dired-get-marked-files))))
      (when files
        (list :label (if (cdr files) (format "%d files" (length files))
                       (file-name-nondirectory (directory-file-name (car files))))
              :text (ema--context-block
                     "files" (format "directory %s (not read: read what you need)"
                                     (abbreviate-file-name default-directory))
                     (mapconcat #'abbreviate-file-name files "\n")))))))

(defun ema-context-compilation (_scope)
  "In a compilation or grep buffer: the message at point and its source."
  (when (derived-mode-p 'compilation-mode)
    (let* ((message (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position)))
           (place (and (get-text-property (line-beginning-position) 'compilation-message)
                       (ignore-errors
                         (save-window-excursion
                           (save-excursion
                             (let ((display-buffer-overriding-action
                                    '(display-buffer-no-window (allow-no-window . t))))
                               (compile-goto-error))
                             (list (current-buffer) (line-number-at-pos))))))))
      (list :label (format "%s:%d" (buffer-name) (line-number-at-pos))
            :text (ema--context-block
                   "message" (format "buffer %s%s" (buffer-name)
                                     (if place (format " | at %s:%d" (buffer-name (car place))
                                                       (cadr place))
                                       ""))
                   (concat message
                           (when place
                             (with-current-buffer (car place)
                               (save-excursion
                                 (ema--goto-line (cadr place))
                                 (concat "\n[source]\n"
                                         (ema--numbered
                                          (line-beginning-position -2)
                                          (line-end-position 4))))))))))))

(defun ema-context-org (scope)
  "In org, for an action on a definition: the subtree at point."
  (when (and (derived-mode-p 'org-mode) (eq scope 'defun))
    (ignore-errors
      (save-excursion
        (org-back-to-heading t)
        (let ((beg (point)) (title (org-get-heading t t t t))
              (end (save-excursion (org-end-of-subtree t) (point))))
          (list :label (format "%s:%s" (buffer-name) (substring-no-properties title))
                :text (ema--context-block
                       "org subtree"
                       (format "%s | lines %d-%d" (ema--context-source)
                               (line-number-at-pos beg) (line-number-at-pos end))
                       (ema--numbered beg (max beg (1- end))))))))))

(defun ema--context-source ()
  "Return \"buffer NAME\" for the current buffer, with its file when it has one."
  (format "buffer %s%s" (buffer-name)
          (if buffer-file-name
              (concat " | file " (abbreviate-file-name buffer-file-name))
            "")))

(defun ema--context-bounds (scope)
  "Return (KIND BEG END) for SCOPE in the current buffer.
An active region always wins.  SCOPE `defun' takes the definition around
point, `buffer' the whole buffer, anything else the line at point."
  (cond
   ((use-region-p)
    (list "region" (region-beginning)
          ;; a region that ends at a line start does not include that line
          (save-excursion (goto-char (region-end))
                          (if (and (bolp) (> (point) (region-beginning)))
                              (1- (point)) (point)))))
   ((eq scope 'buffer) (list "buffer" (point-min) (point-max)))
   ((and (eq scope 'defun) (bounds-of-thing-at-point 'defun))
    (let ((b (bounds-of-thing-at-point 'defun)))
      (list "definition" (car b)
            (save-excursion (goto-char (cdr b))
                            (skip-chars-backward " \t\n") (point)))))
   (t (list "line" (line-beginning-position) (line-end-position)))))

(defun ema--numbered (beg end)
  "Return the text of lines BEG..END (positions) with line numbers."
  (save-excursion
    (goto-char beg)
    (let ((n (line-number-at-pos beg)) (last (line-number-at-pos end)) out)
      (while (<= n last)
        (push (format "%d\t%s" n (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position)))
              out)
        (setq n (1+ n))
        (forward-line 1))
      (string-join (nreverse out) "\n"))))

(defun ema-context (&optional scope)
  "Return the context at point as a plist.
:label is a short reference, :text is the block the model reads.
See `ema--context-bounds' for SCOPE.  Without an active region, the
functions in `ema-context-functions' are asked first."
  (ema--refuse-secret-file buffer-file-name)
  (or (and (not (use-region-p))
           (run-hook-with-args-until-success 'ema-context-functions scope))
      (ema--context-lines scope)))

(defun ema--context-lines (scope)
  "Return the context of SCOPE as numbered lines of the current buffer."
  (pcase-let* ((`(,kind ,beg ,end) (ema--context-bounds scope))
               (from (line-number-at-pos beg))
               (to (line-number-at-pos end))
               (lines (1+ (- to from)))
               (fn (ignore-errors (add-log-current-defun)))
               (diags (ema--diagnostics-between from to)))
    (list
     :label (format "%s:%s" (buffer-name)
                    (if (= from to) from (format "%d-%d" from to)))
     :text
     (concat
      (format "[context: %s | %s | %s%s%s]\n"
              kind (ema--context-source)
              (if (= from to) (format "line %d, column %d" from (current-column))
                (format "lines %d-%d" from to))
              (if (and fn (not (equal kind "buffer"))) (format " | in %s" fn) "")
              (format " | %s" major-mode))
      (if (> lines ema-context-max-lines)
          (format "(%d lines, not included: read them with ema-buffer-text)" lines)
        (ema--numbered beg end))
      (if diags (concat "\n[diagnostics here]\n" (string-join diags "\n")) "")))))

(defun ema--diagnostics-between (from to)
  "Return the flymake diagnostics on lines FROM to TO, one string for each."
  (and (bound-and-true-p flymake-mode)
       (mapcar #'ema--diagnostic-line
               (seq-filter (lambda (d)
                             (<= from (line-number-at-pos (flymake-diagnostic-beg d)) to))
                           (flymake-diagnostics)))))

;;;; Entry points

;;;###autoload
(defun ema-ask-here (question)
  "Ask ema QUESTION about the region, or about the line at point."
  (interactive
   (list (read-string (if (use-region-p) "ema, about the region: "
                        "ema, about this line: "))))
  (let ((ctx (ema-context)))
    (deactivate-mark)
    (ema--show-chat)
    (ema-submit question (list ctx))))

;;;###autoload
(defun ema-add-here ()
  "Add a reference to the region or the line at point to the chat input.
Point moves to the chat; type the question there and send it.  Repeat
the command in other places to send several references in one message."
  (interactive)
  (let ((ctx (ema-context)))
    (deactivate-mark)
    (ema)
    (with-current-buffer (ema--chat-buffer)
      (ema--add-reference ctx))))

(defun ema-ask-file (file question)
  "Ask ema QUESTION about FILE."
  (interactive "fFile: \nsema, about this file: ")
  (ema--show-chat)
  (ema-submit question
              (list (list :label (file-name-nondirectory (directory-file-name file))
                          :text (format "[context: file | %s (not read: read what you need)]"
                                        (abbreviate-file-name (expand-file-name file)))))))

;;;; Actions: a pre-prompt and a scope under one name

(defvar ema-actions
  '((explain  :key "e" :scope defun
              :prompt "Explain what this code does and why it is written this way. Be brief. Point at the important places with ema-show.")
    (review   :key "r" :scope defun
              :prompt "Review this code. Put one ema-note on each finding at its line, bugs and risks first, then give a short summary.")
    (refactor :key "f" :scope defun
              :prompt "Propose a refactoring that makes this code simpler to read, with the same behaviour. Check the usages first. Offer it with ema-suggest, one focused change at a time.")
    (fix      :key "x" :scope line
              :prompt "Something is wrong here. Find the cause, using the diagnostics and the language server, explain it in one or two sentences and offer the fix with ema-suggest.")
    (doc      :key "d" :scope defun
              :prompt "Write the missing documentation for this code in the style this file already uses. Offer it with ema-suggest.")
    (usages   :key "u" :scope line
              :prompt "Find where the symbol at this position is used across the project and summarise how. Show the list with ema-present."))
  "Alist of (NAME . PLIST): :prompt (the pre-prompt), :scope (`defun',
`line' or `buffer'; an active region always wins), :key (a key in
`ema-command-map', or nil).")

(defvar ema-command-map (make-sparse-keymap)
  "Prefix keymap of ema; bind it to a key, such as C-c e.
The fixed keys are set below.  The key of an action is its :key in
`ema-actions'.")

;; The fixed keys.  They are set at every load, not in the `defvar', so
;; that a reload (`ema-restart') adds a new key to the map that exists.
(pcase-dolist (`(,key . ,command)
               '(("a" . ema-ask-here)
                 ("c" . ema-add-here)
                 ("." . ema-act)
                 ("m" . ema-menu)
                 ("]" . ema-next-note)
                 ("[" . ema-previous-note)
                 ("q" . ema-clear-notes)
                 ("o" . ema)
                 ("n" . ema-new)
                 ("h" . ema-resume)
                 ("k" . ema-abort)
                 ("p" . ema-switch-provider)))
  (define-key ema-command-map key command))
(fset 'ema-command-map ema-command-map)

(defun ema--action-command (name)
  "Return the symbol of the command that runs action NAME: ema-act-NAME."
  (intern (format "ema-act-%s" name)))

(defun ema-run-action (name)
  "Send the context at point to ema with the pre-prompt of action NAME."
  (let* ((action (or (alist-get name ema-actions)
                     (user-error "No ema action %s" name)))
         (ctx (ema-context (plist-get action :scope))))
    (deactivate-mark)
    (ema--show-chat)
    (ema-submit (plist-get action :prompt) (list ctx) (symbol-name name))))

(defun ema--install-action (name)
  "Define command ema-act-NAME and bind the key of action NAME."
  (let ((cmd (ema--action-command name))
        (action (alist-get name ema-actions)))
    (defalias cmd
      (lambda () (interactive) (ema-run-action name))
      (format "Run the ema action `%s' on the region or at point.\n\nPre-prompt: %s"
              name (plist-get action :prompt)))
    (when (plist-get action :key)
      (define-key ema-command-map (plist-get action :key) cmd))
    cmd))

;;;###autoload
(defun ema-act ()
  "Pick an ema action from the list and run it here."
  (interactive)
  (let* ((rows (mapcar (lambda (cell)
                         (cons (symbol-name (car cell))
                               (truncate-string-to-width
                                (plist-get (cdr cell) :prompt) 70 nil nil t)))
                       ema-actions))
         (pick (ema--annotated-read "ema action: " rows)))
    (ema-run-action (intern pick))))

;;;; The menu (transient) and embark

(declare-function transient-setup "transient")

(defun ema--menu-title ()
  "Return the title of the menu: the provider and model in use."
  (format "ema · %s" (ema--config-label)))

;;;###autoload
(defun ema-menu ()
  "Show the ema commands and actions in a menu.
The menu is built from `ema-actions' each time, so it shows the
shortcuts that you or ema added."
  (interactive)
  (unless (require 'transient nil t)
    (user-error "The transient library is not available"))
  (let ((actions (delq nil (mapcar
                            (lambda (cell)
                              (let ((key (plist-get (cdr cell) :key)))
                                (and key (list key (symbol-name (car cell))
                                               (ema--action-command (car cell))))))
                            ema-actions))))
    (eval
     `(transient-define-prefix ema--menu ()
        "The ema menu; see `ema-menu'."
        [:description ema--menu-title
         ["Here"
          ("a" "ask about this" ema-ask-here)
          ("c" "add to the chat input" ema-add-here)
          ("." "pick an action" ema-act)]
         ["Actions" ,@actions]
         ["Notes"
          ("]" "next note" ema-next-note :transient t)
          ("[" "previous note" ema-previous-note :transient t)
          ("q" "clear notes" ema-clear-notes)]
         ["Chat"
          ("o" "open" ema)
          ("n" "new conversation" ema-new)
          ("h" "resume from history" ema-resume)
          ("k" "stop" ema-abort)
          ("p" "provider and model" ema-switch-provider)
          ("l" "cell log" ema-cells)]])
     t))
  (transient-setup 'ema--menu))

(defvar embark-target-injection-hooks)
(with-eval-after-load 'embark
  ;; z = ema, in `embark-act' on a region, a symbol, a definition or a file
  (dolist (map '(embark-region-map embark-identifier-map embark-defun-map
                 embark-expression-map embark-symbol-map))
    (when (and (boundp map) (keymapp (symbol-value map)))
      (define-key (symbol-value map) "z" #'ema-ask-here)
      (define-key (symbol-value map) "Z" #'ema-act)))
  (when (boundp 'embark-file-map)
    (define-key (symbol-value 'embark-file-map) "z" #'ema-ask-file))
  ;; these read a question or an action, not the target: do not insert it
  (dolist (cmd '(ema-ask-here ema-act))
    (cl-pushnew 'embark--ignore-target
                (alist-get cmd embark-target-injection-hooks))))

;;;; Actions: the shortcuts of the user

(defvar ema--stored-actions nil
  "The actions the user or the agent added; saved in actions.eld.")

(defun ema-load-actions ()
  "Load the saved actions and define a command for every action."
  (condition-case err
      (when (file-readable-p (ema--state-file "actions.eld"))
        (setq ema--stored-actions (ema--read-state "actions.eld")))
    (error (message "ema: actions not loaded: %s" (error-message-string err))))
  (dolist (cell ema--stored-actions)
    (setf (alist-get (car cell) ema-actions) (cdr cell)))
  (dolist (cell ema-actions)
    (ema--install-action (car cell))))

(ema-deftool ema-actions-list ()
  "Return the user's ema shortcuts: name, key, scope and pre-prompt per line.
An action is a command `ema-act-NAME' that sends the code at the cursor
with a fixed pre-prompt.  Keys are in the prefix map `ema-command-map'."
  (mapconcat (lambda (cell)
               (format "%s  key %s  scope %s  — %s" (car cell)
                       (or (plist-get (cdr cell) :key) "none")
                       (plist-get (cdr cell) :scope)
                       (plist-get (cdr cell) :prompt)))
             ema-actions "\n"))

(ema-deftool ema-action-save (name prompt &optional key scope)
  "Create or replace the shortcut NAME (a symbol): a command with a pre-prompt.
The command `ema-act-NAME' sends the code at the user's cursor to you
with PROMPT as the message.  SCOPE says what is sent when no region is
active: `defun' (the definition around point, the default), `line' or
`buffer'.  KEY is a one-key string in the ema prefix map; check
`(ema-actions-list)` for a free one, or pass nil.  Write PROMPT as an
instruction to yourself: say what to do and with which tool to deliver
it (ema-note, ema-suggest, ema-present).  The action is saved for later
sessions."
  (unless (and (symbolp name) (stringp prompt) (not (string-empty-p prompt)))
    (error "NAME must be a symbol and PROMPT a non-empty string"))
  (when (and key (let ((bound (lookup-key ema-command-map key)))
                   (and bound (not (eq bound (ema--action-command name))))))
    (error "Key %s is taken by %s in the ema prefix map"
           key (lookup-key ema-command-map key)))
  (let ((plist (list :key key :scope (or scope 'defun) :prompt prompt)))
    (setf (alist-get name ema-actions) plist)
    (setf (alist-get name ema--stored-actions) plist)
    (ema--write-state "actions.eld" ema--stored-actions)
    (ema--install-action name)
    (format "saved: M-x ema-act-%s%s" name
            (let ((prefix (where-is-internal ema-command-map nil t)))
              (cond ((and key prefix)
                     (format ", key %s %s" (key-description prefix) key))
                    (key (format ", key %s in ema-command-map (the prefix map is not bound to a key yet)" key))
                    (t ""))))))

(ema-deftool ema-action-delete (name)
  "Remove the shortcut NAME (a symbol), its command and its key."
  (let ((action (alist-get name ema-actions)))
    (unless action (error "No action %s" name))
    (when (plist-get action :key)
      (define-key ema-command-map (plist-get action :key) nil))
    (setq ema-actions (assq-delete-all name ema-actions)
          ema--stored-actions (assq-delete-all name ema--stored-actions))
    (fmakunbound (ema--action-command name))
    (ema--write-state "actions.eld" ema--stored-actions)
    (format "deleted %s" name)))

(ema-load-actions)

(provide 'ema-actions)
;;; ema-actions.el ends here
