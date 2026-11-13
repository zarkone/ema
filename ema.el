;;; ema.el --- A minimal agent that lives in Emacs -*- lexical-binding: t -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience

;;; Commentary:

;; ema is a small agent in the spirit of anybao, with Emacs as the
;; runtime.  The model has ONE tool, `eval': an Emacs Lisp cell that
;; runs in this live Emacs.  Emacs is the persistent kernel: what a cell
;; defines stays defined, and the agent checks every result live, so
;; there is no trace or replay layer.
;;
;;   M-x ema                  open the chat (RET sends, C-j is a newline)
;;   M-x ema-ask              ask from the minibuffer, from any buffer
;;   C-c e …                  after (keymap-global-set "C-c e" ema-command-map):
;;                            a ask here, c add a reference, e/r/f/x/d/u
;;                            actions on the region or at point, . list
;;   M-x ema-switch-provider  change provider or model, also mid-chat
;;   M-x ema-new              start a new conversation
;;
;; Files: ema-llm.el (providers, secrets), ema-tools.el (the documented
;; functions the agent calls and extends), skills/core.md (the prompt).

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'ema-llm)
(require 'ema-tools)
(require 'ema-self)
(require 'ema-org)

(defgroup ema nil "A minimal agent that lives in Emacs." :group 'tools)

(defcustom ema-max-turns 40
  "Model calls allowed for one user message."
  :type 'integer)

(defcustom ema-digest-limit 4000
  "Characters of a cell result shown to the model before it is stubbed."
  :type 'integer)

(defcustom ema-digest-full-limit 30000
  "The limit for a cell that sets full_output."
  :type 'integer)

(defcustom ema-display-action
  '((display-buffer-in-side-window) (side . left) (window-width . 0.4))
  "How `ema' displays the chat buffer (a `display-buffer' action)."
  :type 'sexp)

(defface ema-user '((t :inherit font-lock-keyword-face :weight bold))
  "Face of the user's messages.")
(defface ema-cell '((t :inherit font-lock-doc-face))
  "Face of the code of a cell.")
(defface ema-result '((t :inherit shadow))
  "Face of the result of a cell.")
(defface ema-notice '((t :inherit warning))
  "Face of notices and errors.")

;;;; Cells: the one tool

(defvar ema-values (make-hash-table)
  "Large cell values, by number; read one with `ema-value'.")
(defvar ema--value-seq 0)

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
      (format "%s\n… [%d of %d chars shown. (ema-value %d) returns the whole value: slice or search it, never re-run the call that made it]"
              (substring text 0 limit) limit (length text) n))))

(defun ema--read-all (code)
  "Read every form in string CODE; return them inside one `progn'."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (let (forms)
      (while (progn (forward-comment (point-max)) (not (eobp)))
        (push (read (current-buffer)) forms))
      (cons 'progn (nreverse forms)))))

(defun ema--error-hint (err)
  "Return a hint for error ERR, or an empty string."
  (pcase err
    (`(void-function ,sym)
     (let ((near (apropos-internal (regexp-quote (symbol-name sym)) #'fboundp)))
       (if near (format "\nDefined functions with a similar name: %s"
                        (seq-take near 12))
         "")))
    (`(void-variable ,sym)
     (format "\n%s is not bound. A variable set in an earlier cell persists only when it was set with setq or defvar, not let." sym))
    (_ "")))

(defun ema-eval-cell (code &optional full buffer)
  "Evaluate string CODE in BUFFER's context; return the digest for the model.
The digest holds what the cell printed, new *Messages* lines and the
value of the last form, each cut at the digest limit (`ema-digest-limit',
or the larger one when FULL is non-nil).  An error or a C-g comes back
as text: a cell never signals."
  (let* ((limit (if full ema-digest-full-limit ema-digest-limit))
         (out (generate-new-buffer " *ema-out*"))
         (msg-mark (with-current-buffer (messages-buffer) (point-max-marker)))
         (value nil) (failure nil))
    (unwind-protect
        (progn
          (condition-case err
              (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
                (let ((standard-output out)
                      (inhibit-quit nil))
                  (setq value (eval (ema--read-all code) t))))
            (quit (setq failure "Quit: the user stopped this cell with C-g."))
            (error (setq failure (concat "error: " (error-message-string err)
                                         (ema--error-hint err)))))
          (let ((printed (with-current-buffer out (buffer-string)))
                (messages (with-current-buffer (messages-buffer)
                            (string-trim (buffer-substring-no-properties
                                          msg-mark (point-max))))))
            (concat
             (unless (string-empty-p printed)
               (concat "output:\n" (ema--stub printed printed limit) "\n"))
             (unless (string-empty-p messages)
               (concat "messages:\n" (ema--stub messages messages limit) "\n"))
             (or failure
                 (concat "=> "
                         (ema--stub (if (stringp value) value
                                      (string-trim-right (pp-to-string value)))
                                    value limit))))))
      (kill-buffer out)
      (set-marker msg-mark nil))))

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

;;;; The system prompt

(defun ema--system-prompt ()
  "Build the system prompt: the core skill, the tool list, the skill list."
  (concat (ema-skill "core")
          (ema-self-description)
          "\n## Tools\n\n" (ema-tools-index)
          "\n\n## Skills\n\n"
          (let ((s (ema-skills-index)))
            (if (string-empty-p s) "(none yet)" s))
          (format "\n\n## Environment\n\nEmacs %s on %s. ema state directory: %s\n"
                  emacs-version system-type
                  (abbreviate-file-name ema-directory))))

;;;; The chat buffer

(defvar-local ema--messages nil "The conversation, in the neutral shape.")
(defvar-local ema--system nil "The system prompt of this conversation.")
(defvar-local ema--busy nil "Non-nil while a turn runs.")
(defvar-local ema--generation 0 "Bumped by abort; stale replies are dropped.")
(defvar-local ema--request nil "The buffer of the request in flight.")
(defvar-local ema--origin nil "The buffer the user worked in when they sent.")
(defvar-local ema--turns 0 "Model calls made for the current user message.")
(defvar-local ema--usage nil "Token totals: (:in N :cached N :out N).")
(defvar-local ema--out nil "Marker: where transcript text is inserted.")
(defvar-local ema--input nil "Marker: where the user's input starts.")
(defvar-local ema--pending nil "Contexts added to the input, newest first.")
(defvar-local ema--qend nil "Marker: the end of the live cell queue.")
(defvar-local ema--cells nil "Cells of the running turn, newest first: (N STATE LINE).")
(defvar-local ema--cell-count 0 "Cells run in this conversation.")
(defvar-local ema--phase nil "What the turn waits for: `model' or `cell'.")

(defvar ema-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ema-send-or-newline)
    (define-key map (kbd "C-c C-c") #'ema-send)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-c C-k") #'ema-abort)
    (define-key map (kbd "C-c C-n") #'ema-new)
    (define-key map (kbd "C-c C-p") #'ema-switch-provider)
    (define-key map (kbd "C-c C-r") #'ema-continue)
    (define-key map (kbd "C-c C-l") #'ema-cells)
    (define-key map (kbd "M-p") #'ema-history-previous)
    (define-key map (kbd "M-n") #'ema-history-next)
    map))

(define-derived-mode ema-mode text-mode "ema"
  "The ema chat.  Type after the prompt; RET sends, C-j inserts a newline."
  (visual-line-mode 1)
  (setq-local header-line-format '(:eval (ema--header))))

(defconst ema--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])
(defvar ema--spin 0 "The current spinner frame.")
(defvar ema--spin-timer nil)

(defun ema--spinner ()
  (aref ema--spinner-frames (% ema--spin (length ema--spinner-frames))))

(defun ema--spin-start ()
  "Animate the spinner while a turn runs."
  (unless ema--spin-timer
    (setq ema--spin-timer
          (run-at-time 0 0.12
                       (lambda ()
                         (setq ema--spin (1+ ema--spin))
                         (force-mode-line-update t))))))

(defun ema--spin-stop ()
  (when ema--spin-timer
    (cancel-timer ema--spin-timer)
    (setq ema--spin-timer nil))
  (force-mode-line-update t))

(defun ema--activity ()
  "Describe what the running turn does now, or return nil when idle."
  (when ema--busy
    (or ema-status-text
        (if (eq ema--phase 'cell)
            (format "running cell #%d" ema--cell-count)
          (format "waiting for the model, call %d" ema--turns)))))

(defun ema-mode-line ()
  "The global indicator: a spinner and the activity while ema works."
  (let ((chat (get-buffer "*ema*")))
    (if (and chat (buffer-local-value 'ema--busy chat))
        (propertize (format " ema %s %s " (ema--spinner)
                            (with-current-buffer chat (ema--activity)))
                    'face 'ema-notice
                    'help-echo "ema is working; mouse-1 shows the chat"
                    'mouse-face 'mode-line-highlight
                    'local-map (let ((map (make-sparse-keymap)))
                                 (define-key map [mode-line mouse-1] #'ema)
                                 map))
      "")))
(put 'ema-mode-line 'risky-local-variable t)

(unless (member '(:eval (ema-mode-line)) global-mode-string)
  (setq global-mode-string
        (append (or global-mode-string '("")) '((:eval (ema-mode-line))))))

(defun ema--human-number (n)
  "Format token count N rounded: 950, 1.2K, 35K, 1.2M, 35M."
  (cl-flet ((scaled (x suffix)
              (if (< x 10)
                  (format "%.1f%s" x suffix)
                (format "%d%s" (round x) suffix))))
    (cond ((< n 1000) (number-to-string n))
          ((< n 999500) (scaled (/ n 1000.0) "K"))
          (t (scaled (/ n 1000000.0) "M")))))

(defun ema--header ()
  (let ((p (ema-provider-plist)))
    (format " %s/%s  ·  in %s (cached %s)  out %s%s"
            ema-provider (plist-get p :model)
            (ema--human-number (or (plist-get ema--usage :in) 0))
            (ema--human-number (or (plist-get ema--usage :cached) 0))
            (ema--human-number (or (plist-get ema--usage :out) 0))
            (if ema--busy
                (format "  ·  %s %s  (C-c C-k stops)" (ema--spinner) (ema--activity))
              ""))))

(defun ema--reset ()
  "Erase the chat buffer and start a new conversation in it."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "› " 'face 'ema-user 'read-only t
                        'rear-nonsticky t 'front-sticky t))
    (setq ema--out (copy-marker (point-min) nil)
          ema--qend (copy-marker (point-min) t)
          ema--input (copy-marker (point-max) nil)
          ema--cells nil
          ema--cell-count 0
          ema--phase nil
          ema--messages nil
          ema--system (ema--system-prompt)
          ema--busy nil
          ema--pending nil
          ema--turns 0
          ema--usage nil)
    (cl-incf ema--generation)
    (goto-char (point-max))))

(defun ema--insert (text &optional face)
  "Insert TEXT in the transcript, above the prompt."
  (let ((inhibit-read-only t)
        (at-end (= (point) (point-max))))
    (save-excursion
      (goto-char ema--out)
      (insert (if face (propertize text 'face face) text))
      (set-marker ema--out (point)))
    (when at-end (goto-char (point-max)))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (when (>= (window-point w) ema--input)
        (with-selected-window w (recenter -1))))))

(defconst ema--path-regexp
  "\\(?:~\\|\\.\\.?\\)?/?[[:alnum:]_.+@-]+\\(?:/[[:alnum:]_.+@-]+\\)*"
  "Matches a candidate file path in a reply.")

(defun ema--open-link (button)
  "Show the file of BUTTON, at its line, beside the chat."
  (ema-show (button-get button 'ema-file) (button-get button 'ema-line)))

(defun ema--linkify (beg end)
  "Make each existing file path between BEG and END a link.
A path is relative to `default-directory', the project of the buffer the
user works in.  A \":LINE\" after the path is where the link goes."
  (unless (file-remote-p default-directory)
    (save-excursion
      (goto-char beg)
      (let ((inhibit-read-only t) (case-fold-search nil))
        (while (re-search-forward ema--path-regexp end t)
          (let* ((pbeg (match-beginning 0))
                 (path (string-trim-right (match-string-no-properties 0) "[.]+"))
                 (pend (+ pbeg (length path)))
                 (line (save-excursion
                         (goto-char pend)
                         (and (looking-at ":\\([0-9]+\\)")
                              (prog1 (string-to-number (match-string 1))
                                (setq pend (match-end 0)))))))
            (when (and (string-match-p "[/.]" path)
                       (not (member path '("." ".." "/")))
                       (file-regular-p (expand-file-name path)))
              (make-text-button pbeg pend
                                'action #'ema--open-link
                                'follow-link t
                                'help-echo "RET or mouse: show this place"
                                'ema-file (expand-file-name path)
                                'ema-line line))
            (goto-char (max pend (point)))))))))

(defun ema--chat-buffer ()
  (let ((buf (get-buffer-create "*ema*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'ema-mode)
        (ema-mode)
        (ema--reset)))
    buf))

;;;###autoload
(defun ema ()
  "Open the ema chat."
  (interactive)
  (let ((buf (ema--chat-buffer)))
    (select-window (display-buffer buf ema-display-action))
    (goto-char (point-max))))

(defun ema-new ()
  "Start a new conversation.  The tool and skill lists are read again."
  (interactive)
  (with-current-buffer (ema--chat-buffer)
    (ema-abort)
    (ema--reset)))

(defun ema-abort ()
  "Stop the running turn."
  (interactive)
  (with-current-buffer (ema--chat-buffer)
    (cl-incf ema--generation)
    (when (buffer-live-p ema--request)
      (let ((proc (get-buffer-process ema--request))
            (kill-buffer-query-functions nil))
        (when proc (delete-process proc))
        (kill-buffer ema--request)))
    (when ema--busy
      (ema--finish "\n[stopped]\n"))
    (force-mode-line-update)))

;;;; The loop

(defun ema--origin-buffer ()
  "The buffer of the most recently used window that is not an ema chat."
  (let ((wins (sort (seq-remove
                     (lambda (w) (with-current-buffer (window-buffer w)
                                   (derived-mode-p 'ema-mode)))
                     (window-list (selected-frame) 'no-minibuf))
                    (lambda (a b) (> (window-use-time a) (window-use-time b))))))
    (and wins (window-buffer (car wins)))))

(defun ema--push (role content)
  (setq ema--messages
        (append ema--messages (list (list :role role :content content)))))

(defun ema-submit (text &optional contexts title)
  "Send TEXT as the user's message in the chat buffer and run the turn.
CONTEXTS is a list of context plists (see `ema-context') whose text goes
to the model before TEXT.  TITLE, when given, is shown in the transcript
in place of TEXT (an action shows its name, not its pre-prompt)."
  (let ((caller (and (not (derived-mode-p 'ema-mode))
                     (not (minibufferp))
                     (current-buffer))))
   (with-current-buffer (ema--chat-buffer)
    (when ema--busy (user-error "ema is working; C-c C-k stops it"))
    (setq ema--origin (or caller (ema--origin-buffer))
          ema--turns 0
          ema--busy t)
    ;; relative paths in the chat (links, ffap, embark) resolve in the project
    (when (buffer-live-p ema--origin)
      (setq default-directory
            (with-current-buffer ema--origin
              (let ((pr (ignore-errors (project-current nil))))
                (if pr (expand-file-name (project-root pr)) default-directory)))))
    (ema--insert (concat "\n› " (or title text)
                         (if contexts
                             (concat "  "
                                     (mapconcat (lambda (c)
                                                  (format "⟨%s⟩" (plist-get c :label)))
                                                contexts " "))
                           "")
                         "\n")
                 'ema-user)
    (ema--push "user"
               (vector (list :type "text"
                             :text (format "[%s]\n[view]\n%s\n\n%s%s"
                                           (format-time-string "%Y-%m-%d %H:%M %a")
                                           (ema-view)
                                           (mapconcat (lambda (c)
                                                        (concat (plist-get c :text) "\n\n"))
                                                      contexts "")
                                           text))))
    (ema--step))))

(defvar ema-input-history nil
  "Inputs sent in the chat, newest first; kept across `ema-new'.")
(defvar-local ema--history-index -1
  "Position in `ema-input-history' shown in the input; -1 is the draft.")
(defvar-local ema--history-draft nil
  "The unsent input saved when history browsing started.")

(defun ema--history-show (index)
  "Replace the input with history entry INDEX; -1 restores the draft."
  (when (= ema--history-index -1)
    (setq ema--history-draft
          (buffer-substring-no-properties ema--input (point-max))))
  (setq ema--history-index index)
  (delete-region ema--input (point-max))
  (goto-char (point-max))
  (insert (if (= index -1)
              (or ema--history-draft "")
            (nth index ema-input-history))))

(defun ema-history-previous ()
  "Replace the input with the previous sent input."
  (interactive)
  (let ((i (1+ ema--history-index)))
    (if (>= i (length ema-input-history))
        (user-error "No earlier input")
      (ema--history-show i))))

(defun ema-history-next ()
  "Replace the input with the next sent input, or the draft after the newest."
  (interactive)
  (if (< ema--history-index 0)
      (user-error "No later input")
    (ema--history-show (1- ema--history-index))))

(defun ema-send ()
  "Send the text typed after the prompt, with the references added to it."
  (interactive)
  (let* ((raw (buffer-substring-no-properties ema--input (point-max)))
         ;; a reference counts only while its tag is still in the input
         (contexts (seq-filter
                    (lambda (c) (string-search (format "⟨%s⟩" (plist-get c :label)) raw))
                    (reverse ema--pending)))
         (text (string-trim (replace-regexp-in-string "⟨[^⟩\n]*⟩ ?" "" raw))))
    (when (and (string-empty-p text) (null contexts))
      (user-error "Nothing to send"))
    (when ema--busy (user-error "ema is working; C-c C-k stops it"))
    (unless (or (string-empty-p text) (equal text (car ema-input-history)))
      (push text ema-input-history))
    (setq ema--history-index -1
          ema--history-draft nil)
    (delete-region ema--input (point-max))
    (setq ema--pending nil)
    (ema-submit (if (string-empty-p text) "Look at this." text) contexts)))

(defun ema-send-or-newline ()
  "Send when point is in the input; else insert a newline."
  (interactive)
  (if (>= (point) ema--input) (ema-send) (newline)))

;;;###autoload
(defun ema-ask (text)
  "Ask ema TEXT from the minibuffer; the current buffer is the context."
  (interactive "sema: ")
  (let ((origin (selected-window)))
    (display-buffer (ema--chat-buffer) ema-display-action)
    (select-window origin)
    (ema-submit text)))

(defun ema-continue ()
  "Call the model again on the conversation as it is (after an error)."
  (interactive)
  (with-current-buffer (ema--chat-buffer)
    (when ema--busy (user-error "ema is working"))
    (unless ema--messages (user-error "No conversation yet"))
    (setq ema--busy t ema--turns 0)
    (ema--step)))

(defun ema--step ()
  "Make one model call for the chat buffer (the current buffer)."
  (let ((chat (current-buffer))
        (gen ema--generation))
    (cl-incf ema--turns)
    (setq ema--phase 'model)
    (ema--spin-start)
    (force-mode-line-update t)
    (condition-case err
        (setq ema--request
              (ema-llm-request
               ema--system ema--messages (list ema--tool)
               (lambda (reply)
                 (when (buffer-live-p chat)
                   (with-current-buffer chat
                     (when (= gen ema--generation)
                       (ema--on-reply reply)))))))
      ;; only the first line: url.el puts the whole request, key
      ;; included, into some of its error messages
      (error (ema--finish
              (format "\n[%s]\n"
                      (truncate-string-to-width
                       (car (split-string (error-message-string err) "[\r\n]"))
                       160 nil nil t)))))))

(defun ema--finish (&optional notice)
  (setq ema--busy nil
        ema--phase nil
        ema-status-text nil)
  (ema--spin-stop)
  (ema--close-change-groups)
  (ema--settle-queue)
  (when notice (ema--insert notice 'ema-notice))
  (force-mode-line-update))

(defun ema--add-usage (u)
  (dolist (k '(:in :cached :out))
    (setq ema--usage (plist-put ema--usage k
                                (+ (or (plist-get ema--usage k) 0)
                                   (or (plist-get u k) 0))))))

;;;; The cell log (every cell, live) and the queue (the last few, in the chat)

(defcustom ema-queue-length 4
  "How many of the latest cells the chat shows while a turn runs."
  :type 'integer)

(defvar ema-log-buffer-name "*ema-cells*")

(define-derived-mode ema-log-mode special-mode "ema-cells"
  "The live log of the cells ema ran: code and result, read-only."
  (setq-local truncate-lines nil))

(defun ema--log-buffer ()
  (let ((buf (get-buffer-create ema-log-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ema-log-mode) (ema-log-mode)))
    buf))

(defun ema--log (text &optional face)
  "Append TEXT to the cell log; windows that show its end follow it."
  (with-current-buffer (ema--log-buffer)
    (let ((inhibit-read-only t)
          (followers (seq-filter (lambda (w) (= (window-point w) (point-max)))
                                 (get-buffer-window-list nil nil t))))
      (save-excursion
        (goto-char (point-max))
        (insert (if face (propertize text 'face face) text)))
      (dolist (w followers) (set-window-point w (point-max))))))

(defun ema-cells (&optional n)
  "Show the live cell log; with N, go to cell number N."
  (interactive)
  (let ((win (ema--side-window (ema--log-buffer))))
    (with-selected-window win
      (if (and n (progn (goto-char (point-min))
                        (re-search-forward (format "^── #%d " n) nil t)))
          (progn (beginning-of-line) (recenter 0))
        (goto-char (point-max))
        (recenter -1)))))

(defun ema--first-line (code)
  (let ((line (car (split-string (string-trim code) "\n"))))
    (truncate-string-to-width line 68 nil nil t)))

(defun ema--render-queue ()
  "Redraw the live queue: the last cells of this turn and the log link."
  (let ((inhibit-read-only t))
    (save-excursion
      (delete-region ema--out ema--qend)
      (when ema--cells
        (goto-char ema--out)
        (let ((start (point)))
          (insert "\n")
          (dolist (cell (reverse (seq-take ema--cells ema-queue-length)))
            (pcase-let ((`(,n ,state ,line) cell))
              (insert-text-button
               (format "  %s #%d  %s"
                       (pcase state ('running "▶") ('error "✗") (_ "✓")) n line)
               'face (if (eq state 'error) 'ema-notice 'ema-cell)
               'help-echo "Show this cell in the log"
               'follow-link t
               'action (lambda (_) (ema-cells n)))
              (insert "\n")))
          (insert "  ")
          (insert-text-button
           (format "[%d cell%s this turn · live log]"
                   (length ema--cells) (if (cdr ema--cells) "s" ""))
           'face 'ema-result 'follow-link t
           'help-echo "Open the live log of all cells (C-c C-l)"
           'action (lambda (_) (ema-cells)))
          (insert "\n")
          (set-marker ema--out start))))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (when (>= (window-point w) ema--input)
        (with-selected-window w (recenter -1))))))

(defun ema--settle-queue ()
  "End of the turn: replace the live queue with one line that links to the log."
  (when ema--cells
    (let* ((cells ema--cells)
           (first (car (car (last cells))))
           (last-n (car (car cells)))
           (inhibit-read-only t))
      (setq ema--cells nil)
      (ema--render-queue)
      (save-excursion
        (goto-char ema--out)
        (insert "  ")
        (insert-text-button
         (if (= first last-n) (format "▸ cell #%d" first)
           (format "▸ %d cells, #%d–#%d" (length cells) first last-n))
         'face 'ema-result 'follow-link t
         'help-echo "Show these cells in the log"
         'action (lambda (_) (ema-cells first)))
        (insert "\n")
        (set-marker ema--out (point))))))

(defun ema--run-cell (code full)
  "Run CODE as the next cell: log it, show it in the queue, return the digest."
  (let ((n (cl-incf ema--cell-count)))
    (push (list n 'running (ema--first-line code)) ema--cells)
    (setq ema--phase 'cell)
    (ema--log (format "── #%d · %s ──\n" n (format-time-string "%H:%M:%S")) 'ema-user)
    (ema--log (concat (string-trim code) "\n") 'ema-cell)
    (ema--render-queue)
    (redisplay)
    (let ((digest (ema-eval-cell code full ema--origin)))
      (setf (nth 1 (car ema--cells))
            (if (string-match-p "^\\(?:error: \\|Quit: \\)" digest)
                'error 'done))
      (ema--log (concat digest "\n\n") 'ema-result)
      (ema--render-queue)
      (redisplay)
      digest)))

(defun ema--on-reply (reply)
  "Handle one model REPLY: show text, run cells, continue or end the turn."
  (if (plist-get reply :error)
      (ema--finish (format "\n[%s — C-c C-r tries again]\n" (plist-get reply :error)))
    (ema--add-usage (plist-get reply :usage))
    (let ((content (plist-get reply :content))
          (stop (plist-get reply :stop))
          results)
      (when (> (length content) 0)
        (ema--push "assistant" content))
      (seq-doseq (block content)
        (pcase (plist-get block :type)
          ("text"
           (let ((from (marker-position ema--out)))
             (ema--insert (concat "\n" (string-trim (plist-get block :text)) "\n"))
             (ema--linkify from (marker-position ema--out))))
          ("tool_use"
           (let* ((input (plist-get block :input))
                  (code (plist-get input :code))
                  (digest
                   (cond ((not (equal (plist-get block :name) "eval"))
                          (format "error: no tool %s; the only tool is eval"
                                  (plist-get block :name)))
                         ((not (stringp code))
                          "error: the eval tool needs a string `code`")
                         (t (ema--run-cell
                             code (eq (plist-get input :full_output) t))))))
             (push (list :type "tool_result"
                         :tool_use_id (plist-get block :id)
                         :content digest)
                   results)))))
      (cond
       (results
        (ema--push "user" (vconcat (nreverse results)))
        (if (>= ema--turns ema-max-turns)
            (ema--finish (format "\n[stopped after %d model calls — C-c C-r continues]\n"
                                 ema--turns))
          (ema--step)))
       ((equal stop "max_tokens")
        (ema--finish "\n[the reply hit the output limit — C-c C-r continues]\n"))
       ((equal stop "refusal")
        (ema--finish "\n[the model declined this request]\n"))
       (t (ema--finish))))))

(ema-load-config)
(ema-load-tools)

(provide 'ema)

;; the DWIM commands need `ema-submit', so they load last
(require 'ema-actions)
;;; ema.el ends here
