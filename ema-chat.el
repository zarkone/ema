;;; ema-chat.el --- The chat buffer: state, transcript, input, cell queue -*- lexical-binding: t -*-

;;; Commentary:

;; A chat is a buffer in `ema-mode'.  Each project has one chat,
;; "*ema: NAME*"; buffers outside a project share "*ema*".
;;
;; The buffer, top to bottom:
;;
;;   transcript    the requests of the user and the replies; read-only
;;   cell queue    only while a turn runs: its last cells, one line each
;;   › input       what the user types, after the prompt
;;
;; Three markers hold this layout:
;;
;;   `ema--out'    where the next transcript text goes: the start of the
;;                 queue
;;   `ema--qend'   the end of the queue
;;   `ema--input'  the start of the input, after the prompt
;;
;; This file is the view: it keeps the state of a chat and draws it.
;; ema.el is the conversation: it sends the input, calls the model and
;; runs the cells.
;;
;; The file, top to bottom:
;;
;;   Options and faces
;;   The state of a chat        every buffer-local variable, and the reset
;;   The mode and its keys
;;   The chat of a project      find it, make it, show it
;;   The header                 tokens, speed, the spinner
;;   The transcript             insert text, links to files
;;   The input                  references, earlier inputs
;;   The cell log               every cell and its result, in one buffer
;;   The cell queue             the last cells of the turn, in the chat

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'ema-llm)
(require 'ema-tools)

;; ema.el loads this file.  It defines the commands that the keymap
;; binds and the prompt of a new conversation.
(declare-function ema-send "ema")
(declare-function ema-send-or-newline "ema")
(declare-function ema-abort "ema")
(declare-function ema-new "ema")
(declare-function ema-continue "ema")
(declare-function ema-resume "ema")
(declare-function ema--system-prompt "ema")
(declare-function ema-switch-provider "ema-self")

;;;; Options and faces

(defcustom ema-display-action
  '((display-buffer-in-side-window) (side . left) (window-width . (body-columns . 80)))
  "How `ema' displays the chat buffer (a `display-buffer' action)."
  :type 'sexp :group 'ema)

(defcustom ema-queue-length 4
  "How many of the latest cells the chat shows while a turn runs."
  :type 'integer :group 'ema)

(defface ema-user '((t :inherit font-lock-keyword-face :weight bold))
  "Face of the user's messages."
  :group 'ema)
(defface ema-cell '((t :inherit font-lock-doc-face))
  "Face of the code of a cell."
  :group 'ema)
(defface ema-result '((t :inherit shadow))
  "Face of the result of a cell."
  :group 'ema)
(defface ema-notice '((t :inherit warning))
  "Face of notices and errors."
  :group 'ema)

;;;; The state of a chat

;; Every variable here is local to a chat buffer.  A new variable that
;; belongs to one conversation also needs a line in `ema--reset'.

;; The chat and its project: these stay for the life of the buffer.
(defvar-local ema--project nil "The project root of this chat, or nil.")
(defvar-local ema--tag "" "The project name of this chat, or the empty string.")

;; The conversation.
(defvar-local ema--messages nil "The conversation, in the neutral shape.")
(defvar-local ema--system nil "The system prompt of this conversation.")
(defvar-local ema--conversation nil "The id of this conversation in the history.")
(defvar-local ema--requests nil "The user's requests, newest first: (SEQ . TEXT).")
(defvar-local ema--window-start 0 "Index of the first message that is sent.")
(defvar-local ema--cell-count 0 "Cells run in this conversation.")

;; The running turn.
(defvar-local ema--busy nil "Non-nil while a turn runs.")
(defvar-local ema--generation 0 "Bumped by abort; stale replies are dropped.")
(defvar-local ema--request nil "The buffer of the request in flight.")
(defvar-local ema--origin nil "The buffer the user worked in when they sent.")
(defvar-local ema--turns 0 "Model calls made for the current user message.")
(defvar-local ema--call-start nil "When the model call in flight started.")
(defvar-local ema--cells nil "Cells of the running turn, newest first: (N STATE LINE).")

;; The numbers of the header.
(defvar-local ema--usage nil "Token totals: (:in N :cached N :out N).")
(defvar-local ema--speed nil "Tokens per second of the last model call.")
(defvar-local ema--last-input 0 "Input tokens of the latest model call.")

;; The layout of the buffer (see the commentary) and the input.
(defvar-local ema--out nil "Marker: where transcript text is inserted.")
(defvar-local ema--qend nil "Marker: the end of the live cell queue.")
(defvar-local ema--input nil "Marker: where the user's input starts.")
(defvar-local ema--pending nil "Contexts added to the input, newest first.")

(defun ema--reset ()
  "Erase the chat buffer and start a new conversation in it."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "› " 'face 'ema-user 'read-only t
                        'rear-nonsticky t 'front-sticky t)))
  (setq ema--out (copy-marker (point-min) nil)
        ema--qend (copy-marker (point-min) t)
        ema--input (copy-marker (point-max) nil)
        ema--pending nil
        ;; the conversation
        ema--messages nil
        ema--system (ema--system-prompt)
        ema--conversation nil
        ema--requests nil
        ema--window-start 0
        ema--cell-count 0
        ;; the turn
        ema--busy nil
        ema--turns 0
        ema--cells nil
        ;; the header
        ema--usage nil
        ema--speed nil
        ema--last-input 0)
  ;; a reply to the old conversation that is still on its way is dropped
  (cl-incf ema--generation)
  (goto-char (point-max)))

;;;; The mode and its keys

(defvar ema-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ema-send-or-newline)
    (define-key map (kbd "TAB") #'ema-next-link)
    (define-key map (kbd "<backtab>") #'ema-previous-link)
    (define-key map (kbd "C-c C-c") #'ema-send)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-c C-k") #'ema-abort)
    (define-key map (kbd "C-c C-n") #'ema-new)
    (define-key map (kbd "C-c C-p") #'ema-switch-provider)
    (define-key map (kbd "C-c C-r") #'ema-continue)
    (define-key map (kbd "C-c C-l") #'ema-cells)
    (define-key map (kbd "C-c C-o") #'ema-resume)
    (define-key map (kbd "M-p") #'ema-history-previous)
    (define-key map (kbd "M-n") #'ema-history-next)
    map))

(define-derived-mode ema-mode text-mode "ema"
  "The ema chat.  Type after the prompt; RET sends, C-j inserts a newline.
Each project has its own chat; the chat keeps its project across mode
changes.  Everything above the prompt is read-only."
  (visual-line-mode 1)
  (add-hook 'after-change-functions #'ema--seal-transcript nil t)
  (setq-local header-line-format '(:eval (ema--header)))
  (setq-local mode-line-buffer-identification
              (list (propertized-buffer-identification "%b")
                    '(:eval (ema--model-id)))))

;;;; The chat of a project

(defun ema--chats ()
  "Return the live chat buffers."
  (seq-filter #'ema--chat-p (buffer-list)))

(defun ema--busy-chat ()
  "Return the chat that runs a turn now, or nil."
  (seq-find (lambda (chat) (buffer-local-value 'ema--busy chat)) (ema--chats)))

(defun ema--project-root ()
  "Return the project root of the current buffer, or nil."
  (let ((pr (ignore-errors (project-current nil))))
    (and pr (expand-file-name (project-root pr)))))

(defun ema--chat-buffer ()
  "Return the chat for the current buffer: itself, or the chat of its project.
Each project has one chat, \"*ema: NAME*\"; buffers outside a project
share \"*ema*\"."
  (if (derived-mode-p 'ema-mode)
      (current-buffer)
    (let ((root (ema--project-root)))
      (or (seq-find (lambda (b) (equal (buffer-local-value 'ema--project b) root))
                    (ema--chats))
          (ema--make-chat root)))))

(defun ema--make-chat (root)
  "Make and return the chat of the project with ROOT (nil: no project)."
  (let* ((name (and root (file-name-nondirectory (directory-file-name root))))
         (buf (generate-new-buffer (if name (format "*ema: %s*" name) "*ema*"))))
    (with-current-buffer buf
      (when root (setq default-directory root))
      (ema-mode)
      (setq ema--project root
            ema--tag (or name ""))
      (ema--reset))
    buf))

(defun ema--show-chat ()
  "Display the chat without leaving the current window."
  (let ((win (selected-window)))
    (display-buffer (ema--chat-buffer) ema-display-action)
    (when (window-live-p win) (select-window win))))

;;;; The header: tokens, speed, the spinner

(defconst ema--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])
(defvar ema--spin 0 "The current spinner frame.")
(defvar ema--spin-timer nil "The timer that animates the spinner, or nil.")

(defun ema--spinner ()
  "Return the current frame of the spinner."
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
  "Stop the spinner."
  (when ema--spin-timer
    (cancel-timer ema--spin-timer)
    (setq ema--spin-timer nil))
  (force-mode-line-update t))

(defun ema--activity ()
  "Return the status text a tool set while the turn runs, or nil."
  (and ema--busy ema-status-text))

(defun ema--human-number (n)
  "Format token count N rounded: 950, 1.2K, 35K, 1.2M, 35M."
  (cl-flet ((scaled (x suffix)
              (if (< x 10)
                  (format "%.1f%s" x suffix)
                (format "%d%s" (round x) suffix))))
    (cond ((< n 1000) (number-to-string n))
          ((< n 999500) (scaled (/ n 1000.0) "K"))
          (t (scaled (/ n 1000000.0) "M")))))

(defun ema--config-label ()
  "Return PROVIDER/MODEL in use, with where it was set unless it is the default."
  (let ((c (ema-current-config)))
    (format "%s/%s%s" (plist-get c :provider) (plist-get c :model)
            (pcase (plist-get c :source)
              ('dir-locals " [.dir-locals.el]")
              ('project " [project]")
              (_ "")))))

(defun ema--model-id ()
  "The provider and model in use, for the mode line after the buffer name."
  (concat "  " (ema--config-label)))

(defun ema--header ()
  "Return the header line: project, token totals, speed.
While a turn runs, the spinner and the status text come after them."
  (cl-flet ((tokens (kind) (ema--human-number (or (plist-get ema--usage kind) 0))))
    (format " %s↑%s ⚡%s  out %s (%s/s)%s"
            (if (string-empty-p ema--tag) "" (concat ema--tag "  ·  "))
            (tokens :in) (tokens :cached) (tokens :out)
            (if ema--speed (format "%d" ema--speed) "?")
            (if ema--busy
                (format "  ·  %s%s  (C-c C-k stops)" (ema--spinner)
                        (if-let* ((a (ema--activity))) (concat " " a) ""))
              ""))))

;;;; The transcript

(defun ema--seal-transcript (beg end _len)
  "Make the text written between BEG and END above the input read-only.
It is an `after-change-functions' function: Emacs removes a
`before-change-functions' function that signals an error, so a guard
there works only once.  ema's own writes bind `inhibit-read-only'."
  (when (and ema--input (< beg ema--input))
    (with-silent-modifications
      (add-text-properties beg (min end ema--input) '(read-only t)))))

(defun ema--keep-input-in-view ()
  "Scroll each window whose point is in the input: the buffer end at the bottom."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (>= (window-point w) ema--input)
      (with-selected-window w (recenter -1)))))

(defun ema--insert (text &optional face)
  "Insert TEXT in the transcript, above the cell queue and the prompt."
  (let ((inhibit-read-only t)
        (at-end (= (point) (point-max))))
    (save-excursion
      (goto-char ema--out)
      (insert (if face (propertize text 'face face) text))
      (set-marker ema--out (point)))
    (when at-end (goto-char (point-max)))
    (ema--keep-input-in-view)))

(defun ema--insert-request (text &optional contexts)
  "Insert the user's request TEXT in the transcript, with the tags of CONTEXTS."
  (ema--insert (concat "\n› " text
                       (if contexts
                           (concat "  " (mapconcat #'ema--reference-tag contexts " "))
                         "")
                       "\n")
               'ema-user))

(defun ema--insert-reply (text)
  "Insert the model's reply TEXT in the transcript; its file paths become links."
  (let ((from (marker-position ema--out)))
    (ema--insert (concat "\n" (string-trim text) "\n"))
    (ema--linkify from (marker-position ema--out))))

(defun ema--insert-notice (text)
  "Insert TEXT in the transcript as a notice of ema: \"[TEXT]\" on its own line."
  (ema--insert (format "\n[%s]\n" text) 'ema-notice))

;;; Links to files

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

(defun ema-next-link ()
  "In the input, TAB as usual; in the transcript, go to the next link.
After the last link, go to the input."
  (interactive)
  (if (>= (point) ema--input)
      (indent-for-tab-command)
    (unless (forward-button 1 nil nil t)
      (goto-char (point-max)))))

(defun ema-previous-link ()
  "Go to the previous link; from the input, to the last one."
  (interactive)
  (backward-button 1 nil nil t))

;;;; The input

;; A REFERENCE is a context (see `ema-context') that the user added to
;; the input before they send.  The input shows it as a tag, ⟨LABEL⟩;
;; the context itself waits in `ema--pending'.  A tag that the user
;; deleted takes its reference with it.

(defvar ema-input-history nil
  "Inputs sent in the chat, newest first; kept across `ema-new'.")
(defvar-local ema--input-index -1
  "Position in `ema-input-history' shown in the input; -1 is the draft.")
(defvar-local ema--input-draft nil
  "The unsent input saved when the user started to browse the earlier inputs.")

(defun ema--reference-tag (context)
  "Return the tag that stands for CONTEXT in the input and the transcript."
  (format "⟨%s⟩" (plist-get context :label)))

(defun ema--add-reference (context)
  "Add CONTEXT to the input of this chat as a reference; go to the input end."
  (push context ema--pending)
  (goto-char (point-max))
  (insert (propertize (ema--reference-tag context)
                      'face 'ema-result 'ema-ref (plist-get context :label))
          " "))

(defun ema--take-input ()
  "Empty the input; return (TEXT . CONTEXTS) of what it held.
TEXT is the typed text without the reference tags.  CONTEXTS are the
references whose tag was still there, oldest first.  TEXT goes to
`ema-input-history'.  An input with neither is a `user-error'."
  (let* ((raw (buffer-substring-no-properties ema--input (point-max)))
         (contexts (seq-filter
                    (lambda (c) (string-search (ema--reference-tag c) raw))
                    (reverse ema--pending)))
         (text (string-trim (replace-regexp-in-string "⟨[^⟩\n]*⟩ ?" "" raw))))
    (when (and (string-empty-p text) (null contexts))
      (user-error "Nothing to send"))
    (unless (or (string-empty-p text) (equal text (car ema-input-history)))
      (push text ema-input-history))
    (setq ema--input-index -1
          ema--input-draft nil
          ema--pending nil)
    (delete-region ema--input (point-max))
    (cons text contexts)))

;;; Earlier inputs (M-p, M-n)

(defun ema--show-input (index)
  "Replace the input with entry INDEX of `ema-input-history'.
INDEX -1 restores the draft."
  (when (= ema--input-index -1)
    (setq ema--input-draft
          (buffer-substring-no-properties ema--input (point-max))))
  (setq ema--input-index index)
  (delete-region ema--input (point-max))
  (goto-char (point-max))
  (insert (if (= index -1)
              (or ema--input-draft "")
            (nth index ema-input-history))))

(defun ema-history-previous ()
  "Replace the input with the previous sent input."
  (interactive)
  (let ((i (1+ ema--input-index)))
    (if (>= i (length ema-input-history))
        (user-error "No earlier input")
      (ema--show-input i))))

(defun ema-history-next ()
  "Replace the input with the next sent input, or the draft after the newest."
  (interactive)
  (if (< ema--input-index 0)
      (user-error "No later input")
    (ema--show-input (1- ema--input-index))))

;;;; The cell log: every cell and its result, in one buffer

(defvar ema-log-buffer-name "*ema-cells*"
  "The name of the buffer that holds the cell log of all chats.")

(define-derived-mode ema-log-mode special-mode "ema-cells"
  "The live log of the cells ema ran: code and result, read-only."
  (setq-local truncate-lines nil))

(defun ema--log-buffer ()
  "Return the buffer of the cell log; make it when it is missing."
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

(defun ema--log-tag ()
  "The prefix of this chat's cells in the log."
  (if (string-empty-p ema--tag) "" (concat ema--tag " ")))

(defun ema-cells (&optional n tag)
  "Show the live cell log; with N, go to cell number N of the chat with TAG."
  (interactive)
  (let ((win (ema--side-window (ema--log-buffer))))
    (with-selected-window win
      (if (and n (progn (goto-char (point-min))
                        (re-search-forward
                         (format "^── %s#%d " (regexp-quote (or tag "")) n) nil t)))
          (progn (beginning-of-line) (recenter 0))
        (goto-char (point-max))
        (recenter -1)))))

;;;; The cell queue: the last cells of the turn, in the chat

;; While a turn runs, the chat shows its last cells between `ema--out'
;; and `ema--qend', one line each, redrawn after every change
;; (`ema--render-queue').  When the turn ends, one line that links to
;; the log takes the place of the queue (`ema--settle-queue').

(defun ema--insert-log-link (label face help &optional n tag)
  "Insert LABEL as a link to the cell log; with N, to cell N of the chat with TAG.
FACE is the face of the link and HELP its tooltip."
  (insert-text-button label
                      'face face
                      'follow-link t
                      'help-echo help
                      'action (lambda (_) (ema-cells n tag))))

(defun ema--render-queue ()
  "Redraw the live queue: the last cells of this turn and the log link."
  (let ((inhibit-read-only t)
        (tag (ema--log-tag)))
    (save-excursion
      (delete-region ema--out ema--qend)
      (when ema--cells
        (goto-char ema--out)
        (let ((start (point)))
          (insert "\n")
          (dolist (cell (reverse (seq-take ema--cells ema-queue-length)))
            (pcase-let ((`(,n ,state ,line) cell))
              (ema--insert-log-link
               (format "  %s #%d  %s"
                       (pcase state ('running "▶") ('error "✗") (_ "✓")) n line)
               (if (eq state 'error) 'ema-notice 'ema-cell)
               "Show this cell in the log"
               n tag)
              (insert "\n")))
          (insert "  ")
          (ema--insert-log-link
           (format "[%d cell%s this turn · live log]"
                   (length ema--cells) (if (cdr ema--cells) "s" ""))
           'ema-result
           "Open the live log of all cells (C-c C-l)")
          (insert "\n")
          ;; the queue is after `ema--out': the next reply goes above it
          (set-marker ema--out start))))
    (ema--keep-input-in-view)))

(defun ema--settle-queue ()
  "End of the turn: replace the live queue with one line that links to the log."
  (when ema--cells
    (let* ((cells ema--cells)
           (tag (ema--log-tag))
           (first (car (car (last cells))))
           (last-n (car (car cells)))
           (inhibit-read-only t))
      (setq ema--cells nil)
      (ema--render-queue)
      (save-excursion
        (goto-char ema--out)
        (insert "  ")
        (ema--insert-log-link
         (if (= first last-n) (format "▸ cell #%d" first)
           (format "▸ %d cells, #%d–#%d" (length cells) first last-n))
         'ema-result
         "Show these cells in the log"
         first tag)
        (insert "\n")
        (set-marker ema--out (point))))))

(defun ema--cell-started (n code)
  "Show that cell N with CODE runs now: in the log and in the queue."
  (push (list n 'running (ema--first-line code)) ema--cells)
  (ema--log (format "── %s#%d · %s ──\n" (ema--log-tag) n
                    (format-time-string "%H:%M:%S"))
            'ema-user)
  (ema--log (concat (string-trim code) "\n") 'ema-cell)
  (ema--render-queue)
  (redisplay))

(defun ema--cell-ended (digest status)
  "Show that the running cell ended with DIGEST and STATUS (`done' or `error')."
  (setf (nth 1 (car ema--cells)) status)
  (ema--log (concat digest "\n\n") 'ema-result)
  (ema--render-queue)
  (redisplay))

(provide 'ema-chat)
;;; ema-chat.el ends here
