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
;; The source files, in load order.  Each one starts with a map of its
;; own parts.
;;
;;   ema-llm.el      providers, secrets, the HTTP request to a model
;;   ema-tools.el    `ema-deftool', the tool list of the prompt, the
;;                   built-in tools the agent calls and extends
;;   ema-review.el   tools: notes on lines, suggested changes
;;   ema-history.el  the SQLite history of conversations; memories
;;   ema-self.el     tools: switch the model, change ema's own source
;;   ema-org.el      tools: todos and the org agenda
;;   ema-cell.el     run one cell and build its result for the model
;;   ema-chat.el     the chat buffer: state, transcript, input, queue
;;   ema.el          this file: the conversation
;;   ema-actions.el  the commands of `C-c e': context at point, actions
;;
;;   skills/core.md  the fixed part of the system prompt
;;
;; This file is the conversation.  One TURN is what happens between a
;; request of the user and the reply that ends with text only:
;;
;;   `ema-submit'     adds the request, then
;;   `ema--step'      calls the model with the window of the conversation
;;   `ema--on-reply'  shows the text of the reply and runs its cells;
;;                    with cell results it goes back to `ema--step',
;;                    without them it is the end:
;;   `ema--finish'
;;
;; The file, top to bottom:
;;
;;   The system prompt
;;   Commands           open, new, stop, send, ask, continue
;;   The turn           the four functions above
;;   The window         what of a long conversation the model sees
;;   Resume and forget  earlier conversations

;;; Code:

(require 'cl-lib)
(require 'ema-llm)
(require 'ema-tools)
(require 'ema-review)
(require 'ema-history)
(require 'ema-self)
(require 'ema-org)
(require 'ema-cell)
(require 'ema-chat)

(defgroup ema nil "A minimal agent that lives in Emacs." :group 'tools)

(defcustom ema-max-turns 40
  "Model calls allowed for one user message."
  :type 'integer :group 'ema)

(defcustom ema-context-high 120000
  "Input tokens above which the oldest turns leave the window.
The whole conversation stays in the history database."
  :type 'integer :group 'ema)

(defcustom ema-context-low 60000
  "Input tokens that a trim of the window aims for.
A trim costs one prompt cache miss; a wide gap to `ema-context-high'
makes trims rare."
  :type 'integer :group 'ema)

;;;; The system prompt

(defun ema--system-prompt ()
  "Build the system prompt: the core skill, the tool list, the skill list.
The tool list has a full line only for the most used tools."
  (concat (ema-skill "core")
          (ema-self-description)
          (ema-memory-section ema--project)
          "\n## Tools\n\n" (ema-tools-index (ema-tools-daily))
          "\n\n## Skills\n\n"
          (let ((s (ema-skills-index)))
            (if (string-empty-p s) "(none yet)" s))
          (format "\n\n## Environment\n\nEmacs %s on %s. ema state directory: %s\n"
                  emacs-version system-type
                  (abbreviate-file-name ema-directory))))

;;;; Commands: open, new, stop

;;;###autoload
(defun ema ()
  "Open the ema chat of the current buffer's project."
  (interactive)
  (let ((buf (ema--chat-buffer)))
    (select-window (display-buffer buf ema-display-action))
    (goto-char (point-max))))

(defun ema-new ()
  "Start a new conversation with a clean context in this project's chat.
The tool and skill lists are read again.  The old conversation stays in
the history; `ema-resume' brings it back."
  (interactive)
  (with-current-buffer (ema--chat-buffer)
    (ema-abort)
    (ema--reset)))

(defun ema-abort ()
  "Stop the running turn."
  (interactive)
  (with-current-buffer (ema--chat-buffer)
    ;; a reply that still arrives belongs to an old generation: dropped
    (cl-incf ema--generation)
    (ema-llm-cancel ema--request)
    (when ema--busy
      (ema--finish "stopped"))
    (force-mode-line-update))
  ;; a cell that waits for an answer to a suggestion must end too; last,
  ;; because this leaves the function
  (when ema--suggestion-waiting
    (throw 'ema-suggestion 'decline)))

;;;; Commands: send, ask, continue

(defun ema--refuse-when-busy ()
  "Signal a `user-error' when a chat runs a turn.
One turn at a time, in all chats: ema is a synchronous helper."
  (when-let* ((busy (ema--busy-chat)))
    (user-error "ema is working%s; C-c C-k there stops it"
                (if (eq busy (current-buffer)) ""
                  (format " in %s" (buffer-name busy))))))

(defun ema-send ()
  "Send the text typed after the prompt, with the references added to it."
  (interactive)
  (ema--refuse-when-busy)
  (pcase-let ((`(,text . ,contexts) (ema--take-input)))
    (ema-submit (if (string-empty-p text) "Look at this." text) contexts)))

(defun ema-send-or-newline ()
  "Send when point is in the input; else insert a newline."
  (interactive)
  (if (>= (point) ema--input) (ema-send) (newline)))

;;;###autoload
(defun ema-ask (text)
  "Ask ema TEXT from the minibuffer; the current buffer is the context."
  (interactive "sema: ")
  (ema--show-chat)
  (ema-submit text))

(defun ema-continue ()
  "Call the model again on the conversation as it is (after an error)."
  (interactive)
  (with-current-buffer (ema--chat-buffer)
    (ema--refuse-when-busy)
    (unless ema--messages (user-error "No conversation yet"))
    (setq ema--busy t
          ema--turns 0)
    (ema--step)))

;;;; The turn: request, model call, reply, cells

(defun ema-submit (text &optional contexts title)
  "Send TEXT as the user's message in the chat buffer and run the turn.
CONTEXTS is a list of context plists (see `ema-context') whose text goes
to the model before TEXT.  TITLE, when given, is shown in the transcript
in place of TEXT (an action shows its name, not its pre-prompt)."
  (let ((caller (and (not (derived-mode-p 'ema-mode))
                     (not (minibufferp))
                     (current-buffer))))
    (with-current-buffer (ema--chat-buffer)
      (ema--refuse-when-busy)
      (setq ema--origin (or caller (ema--origin-buffer))
            ema--turns 0
            ema--busy t)
      ;; relative paths in the chat (links, ffap, embark) resolve in the project
      (when (and (null ema--project) (buffer-live-p ema--origin))
        (setq default-directory
              (with-current-buffer ema--origin
                (or (ema--project-root) default-directory))))
      (ema--insert-request (or title text) contexts)
      (ema--push "user" (ema--request-content text contexts) (or title text))
      (ema--step))))

(defun ema--origin-buffer ()
  "The buffer of the most recently used window that is not an ema chat."
  (when-let* ((win (car (ema--user-windows))))
    (window-buffer win)))

(defun ema--request-content (text contexts)
  "Return the content of a request message, as the model reads it.
It holds the time, what the user sees (`ema-view'), the text of each of
CONTEXTS, and TEXT."
  (vector (list :type "text"
                :text (format "[%s]\n[view]\n%s\n\n%s%s"
                              (format-time-string "%Y-%m-%d %H:%M %a")
                              (ema-view)
                              (mapconcat (lambda (c)
                                           (concat (plist-get c :text) "\n\n"))
                                         contexts "")
                              text))))

(defun ema--push (role content &optional request)
  "Append a message to the conversation and record it in the history.
REQUEST is the user's own text when the message is a request."
  (let ((seq (length ema--messages)))
    (setq ema--messages
          (append ema--messages (list (list :role role :content content))))
    (when request (push (cons seq request) ema--requests))
    ;; the first message opens the conversation in the history
    (unless ema--conversation
      (setq ema--conversation
            (ema--history-start ema--project
                                (and request (ema--first-line request))
                                ema--system)))
    (when ema--conversation
      (ema--history-message ema--conversation seq role content request))))

(defun ema--step ()
  "Make one model call for the chat buffer (the current buffer)."
  (let ((chat (current-buffer))
        (generation ema--generation))
    (cl-incf ema--turns)
    (ema--trim-window)
    (setq ema--call-start (float-time))
    (ema--spin-start)
    (force-mode-line-update t)
    (condition-case err
        (setq ema--request
              (ema-llm-request
               ema--system (ema--window-messages) (list ema--tool)
               (lambda (reply)
                 ;; a reply for a killed chat or a stopped turn is dropped
                 (when (buffer-live-p chat)
                   (with-current-buffer chat
                     (when (= generation ema--generation)
                       (ema--on-reply reply)))))))
      ;; only the first line: url.el puts the whole request, key
      ;; included, into some of its error messages
      (error (ema--finish (ema--first-line (error-message-string err) 160))))))

(defun ema--on-reply (reply)
  "Handle one model REPLY: show text, run cells, continue or end the turn."
  (ema--record-call reply)
  (if-let* ((problem (plist-get reply :error)))
      (ema--finish (format "%s — C-c C-r tries again" problem))
    (let ((content (plist-get reply :content)))
      (when (> (length content) 0)
        (ema--push "assistant" content))
      (let ((results (ema--play-reply content)))
        (cond
         ;; no cell ran: the reply is the end of the turn
         ((null results)
          (ema--finish (ema--stop-notice (plist-get reply :stop))))
         (t
          (ema--push "user" (vconcat results))
          (if (>= ema--turns ema-max-turns)
              (ema--finish (format "stopped after %d model calls — C-c C-r continues"
                                   ema--turns))
            (ema--step))))))))

(defun ema--record-call (reply)
  "Record the model call that REPLY answers.
That is the speed for the header, the row in the history and the token
counts."
  (let ((usage (plist-get reply :usage))
        (seconds (and ema--call-start (- (float-time) ema--call-start))))
    ;; a call too fast to trust the clock leaves the last speed
    (when (and usage seconds (> seconds 0.2))
      (setq ema--speed (round (/ (or (plist-get usage :out) 0) seconds))))
    (when ema--conversation
      (ema--history-call ema--conversation
                         (and seconds (round (* 1000 seconds)))
                         usage (plist-get reply :stop) (plist-get reply :error)))
    (when usage
      (setq ema--last-input (+ (or (plist-get usage :in) 0)
                               (or (plist-get usage :cached) 0)))
      (dolist (kind '(:in :cached :out))
        (setq ema--usage (plist-put ema--usage kind
                                    (+ (or (plist-get ema--usage kind) 0)
                                       (or (plist-get usage kind) 0))))))))

(defun ema--stop-notice (stop)
  "Return the notice for a reply without cells that has stop reason STOP, or nil."
  (pcase stop
    ("max_tokens" "the reply hit the output limit — C-c C-r continues")
    ("refusal" "the model declined this request")))

(defun ema--play-reply (content)
  "Show the text blocks of CONTENT and run its tool calls, in order.
Return the tool_result blocks, one for each tool call."
  (let (results)
    (seq-doseq (block content)
      (pcase (plist-get block :type)
        ("text" (ema--insert-reply (plist-get block :text)))
        ("tool_use" (push (ema--tool-result block) results))))
    (nreverse results)))

(defun ema--tool-result (block)
  "Run the tool call BLOCK; return its tool_result block."
  (let* ((input (plist-get block :input))
         (code (plist-get input :code))
         (digest
          (cond ((not (equal (plist-get block :name) "eval"))
                 (format "error: no tool %s; the only tool is eval"
                         (plist-get block :name)))
                ((not (stringp code))
                 "error: the eval tool needs a string `code`")
                (t (ema--run-cell code (eq (plist-get input :full_output) t))))))
    (list :type "tool_result"
          :tool_use_id (plist-get block :id)
          :content digest)))

(defun ema--run-cell (code full)
  "Run CODE as the next cell of this chat; return the digest.
FULL asks for the larger digest limit.  The cell is shown in the log and
in the queue, and recorded in the history."
  (let ((n (cl-incf ema--cell-count)))
    (ema--cell-started n code)
    (let* ((start (float-time))
           (digest (let ((ema--current-chat (current-buffer)))
                     (ema-eval-cell code full ema--origin)))
           (ms (round (* 1000 (- (float-time) start))))
           (status (if (ema--digest-failed-p digest) 'error 'done)))
      (when ema--conversation
        (ema--history-cell ema--conversation n code digest status ms))
      (ema--cell-ended digest status)
      digest)))

(defun ema--finish (&optional notice)
  "End the turn; NOTICE, when given, says in the transcript why it ended."
  (setq ema--busy nil
        ema-status-text nil)
  (ema--spin-stop)
  (ema--close-change-groups)
  (ema--settle-queue)
  (when notice (ema--insert-notice notice))
  (force-mode-line-update))

;;;; The window: what of the conversation the model sees

;; `ema--messages' holds the whole conversation.  The model gets the
;; WINDOW: the messages from `ema--window-start' on, with a note in
;; place of the earlier ones.  The window start moves only when the
;; input passes `ema-context-high', and then by a large step, so that
;; the prompt cache holds between two trims.

(defun ema--request-message-p (message)
  "Non-nil when MESSAGE is a request of the user, not tool results."
  (and (equal (plist-get message :role) "user")
       (seq-every-p (lambda (b) (equal (plist-get b :type) "text"))
                    (plist-get message :content))))

(defun ema--window-messages ()
  "Return the messages to send: the window, with a note for what came before."
  (ema--answer-tool-uses
   (if (= ema--window-start 0)
       ema--messages
     (let* ((window (nthcdr ema--window-start ema--messages))
            (first (car window)))
       (cons (list :role (plist-get first :role)
                   :content (vconcat (vector (list :type "text" :text (ema--window-note)))
                                     (plist-get first :content)))
             (cdr window))))))

(defun ema--window-note ()
  "Return the text that stands for the messages before the window."
  (let ((earlier (seq-filter (lambda (r) (< (car r) ema--window-start))
                             (reverse ema--requests))))
    (format "[The first %d messages of this conversation are not shown. All of it is in the history database%s: read it with ema-history or ema-history-sql.%s]\n\n"
            ema--window-start
            (if ema--conversation (format ", conversation %d" ema--conversation) "")
            (if earlier
                (concat " The user's earlier requests, oldest first:\n"
                        (mapconcat (lambda (r) (concat "- " (ema--first-line (cdr r))))
                                   (last earlier 30) "\n"))
              ""))))

(defun ema--answer-tool-uses (messages)
  "Return MESSAGES with every tool_use answered by a tool_result.
A turn stopped before its cells ran leaves a tool_use without a result;
the API rejects the next request then.  The missing results are added
\(as errors) at the start of the following user message, or as a message
of their own at the end.  The stored history is not changed."
  (let (out)
    (while messages
      (let ((message (pop messages)))
        (push message out)
        (when-let* ((missing (ema--unanswered-tool-uses message (car messages))))
          (let ((fill (vconcat
                       (mapcar (lambda (id)
                                 (list :type "tool_result" :tool_use_id id
                                       :content "error: interrupted before this cell ran"
                                       :is_error t))
                               missing)))
                (next (car messages)))
            (if (and next (equal (plist-get next :role) "user"))
                (setq messages
                      (cons (list :role "user"
                                  :content (vconcat fill (plist-get next :content)))
                            (cdr messages)))
              (push (list :role "user" :content fill) out))))))
    (nreverse out)))

(defun ema--unanswered-tool-uses (message next)
  "Return the ids of the tool calls in MESSAGE that NEXT does not answer.
MESSAGE is a message of the assistant, else the result is nil.  NEXT is
the message after it, or nil."
  (when (equal (plist-get message :role) "assistant")
    (let ((answered (and next
                         (equal (plist-get next :role) "user")
                         (mapcar (lambda (b) (plist-get b :tool_use_id))
                                 (plist-get next :content)))))
      (seq-remove (lambda (id) (member id answered))
                  (delq nil (mapcar (lambda (b)
                                      (and (equal (plist-get b :type) "tool_use")
                                           (plist-get b :id)))
                                    (plist-get message :content)))))))

(defun ema--trim-window ()
  "When the input passed `ema-context-high', move the window start forward.
Nothing is deleted: the messages stay in the buffer's conversation and
in the history."
  (when (> ema--last-input ema-context-high)
    (when-let* ((cut (ema--window-cut)))
      (setq ema--window-start cut
            ema--last-input 0)
      (when ema--conversation
        (ema--history-set-window ema--conversation cut))
      (ema--insert-notice
       (format "the context is long: the model now sees the conversation from message %d on; the rest is in the history"
               cut)))))

(defun ema--window-cut ()
  "Return the index of the message where a trimmed window starts, or nil.
The cut is at a request of the user, so that tool calls keep their
results.  It is the first request from which the rest of the window is
small enough to bring the input down to `ema-context-low'; when no
request is that late, it is the last request.  Sizes are measured in
characters of JSON and scaled by the input tokens of the last call."
  (let* ((window (nthcdr ema--window-start ema--messages))
         (sizes (mapcar (lambda (m) (length (ema--json-encode (plist-get m :content))))
                        window))
         (total (max 1 (apply #'+ sizes)))
         (keep (* total (/ (float ema-context-low) ema--last-input)))
         (rest total)                   ; the size from INDEX to the end
         (index ema--window-start)
         cut last-request)
    (while (and window (null cut))
      (when (and (> index ema--window-start)
                 (ema--request-message-p (car window)))
        (if (<= rest keep)
            (setq cut index)
          (setq last-request index)))
      (setq rest (- rest (pop sizes))
            window (cdr window)
            index (1+ index)))
    (or cut last-request)))

;;;; Resume and forget

(defun ema--pick-conversation (prompt)
  "Read one of this chat's project's conversations with PROMPT; return its id."
  (let* ((project (buffer-local-value 'ema--project (ema--chat-buffer)))
         (rows (mapcar (lambda (r)
                         (cons (format "#%d %s" (nth 0 r) (nth 2 r))
                               (format "%s · %d messages"
                                       (format-time-string "%Y-%m-%d %H:%M" (nth 1 r))
                                       (nth 3 r))))
                       (ema--history-conversations project))))
    (unless rows (user-error "No conversations in the history for this project"))
    (let ((pick (ema--annotated-read prompt rows t)))
      (and (string-match "\\`#\\([0-9]+\\)" pick)
           (string-to-number (match-string 1 pick))))))

(defun ema-resume (id)
  "Continue an earlier conversation of this project in its chat.
Interactively, pick it from the list.  The transcript shows the
requests and the replies; the cells are in the history database."
  (interactive (list (ema--pick-conversation "Resume conversation: ")))
  (let ((data (or (ema--history-load id)
                  (user-error "The history database is off"))))
    (with-current-buffer (ema--chat-buffer)
      (ema-abort)
      (ema--reset)
      (setq ema--conversation id
            ema--messages (plist-get data :messages)
            ema--requests (reverse (plist-get data :requests))
            ema--window-start (plist-get data :window-start)
            ema--cell-count (plist-get data :cells))
      (ema--replay-transcript)
      (ema--insert-notice (format "resumed conversation %d" id)))
    (display-buffer (ema--chat-buffer) ema-display-action)))

(defun ema--replay-transcript ()
  "Write the transcript of the conversation that `ema-resume' loaded.
A request is shown as the user typed it; a reply as its text and the
number of its cells."
  (let ((seq 0))
    (dolist (message ema--messages)
      (if-let* ((request (cdr (assq seq ema--requests))))
          (ema--insert-request request)
        (when (equal (plist-get message :role) "assistant")
          (ema--replay-reply (plist-get message :content))))
      (cl-incf seq))))

(defun ema--replay-reply (content)
  "Write the reply with CONTENT to the transcript: its text, a count of its cells."
  (let ((cells 0))
    (seq-doseq (block content)
      (pcase (plist-get block :type)
        ("text" (ema--insert-reply (plist-get block :text)))
        ("tool_use" (cl-incf cells))))
    (when (> cells 0)
      (ema--insert (format "  ▸ %d cell%s\n" cells (if (> cells 1) "s" ""))
                   'ema-result))))

(defun ema-forget (id)
  "Delete an earlier conversation of this project from the history."
  (interactive (list (ema--pick-conversation "Delete conversation: ")))
  (when (yes-or-no-p (format "Delete conversation %d from the history? " id))
    (ema-history-delete id)
    (dolist (chat (ema--chats))
      (with-current-buffer chat
        (when (eql ema--conversation id) (setq ema--conversation nil))))
    (message "ema: conversation %d deleted" id)))

;;;; Load the saved state

(ema-load-config)
(ema-load-tools)

(provide 'ema)

;; ema-actions.el needs `ema-submit' and requires this file, so it loads
;; after the `provide'.
(require 'ema-actions)
;;; ema.el ends here
