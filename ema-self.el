;;; ema-self.el --- The agent's knowledge of itself -*- lexical-binding: t -*-

;;; Commentary:

;; Tools with which the agent inspects and changes its own setup: the
;; provider configurations, the model in use, its source files.
;;
;; A provider change is never blind.  `ema-provider-test' makes a real
;; call through an independent adapter instance (`ema-llm-request' with
;; an explicit provider plist), and the switch happens only when that
;; call returns a working tool call.

;;; Code:

(require 'ema-llm)
(require 'ema-tools)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(defvar ema-source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of ema's own source files.")

;;;; Saved configuration

(defun ema--config-file ()
  (expand-file-name "config.eld" ema-directory))

(defun ema-save-config ()
  "Save the provider configurations and the current provider."
  (make-directory ema-directory t)
  (with-temp-file (ema--config-file)
    (let ((print-length nil) (print-level nil))
      (pp (list :provider ema-provider :providers ema-providers)
          (current-buffer)))))

(defun ema-load-config ()
  "Load the saved provider configurations over the defaults."
  (let ((file (ema--config-file)))
    (when (file-readable-p file)
      (condition-case err
          (let ((cfg (with-temp-buffer
                       (insert-file-contents file)
                       (read (current-buffer)))))
            (dolist (cell (plist-get cfg :providers))
              (setf (alist-get (car cell) ema-providers) (cdr cell)))
            (when (alist-get (plist-get cfg :provider) ema-providers)
              (setq ema-provider (plist-get cfg :provider))))
        (error (message "ema: config not loaded: %s"
                        (error-message-string err)))))))

;;;; Inspect

(defun ema--has-key-p (plist)
  "Non-nil when provider PLIST needs no key or its key can be read."
  (or (null (plist-get plist :key))
      (and (ignore-errors (funcall ema-secret-function (plist-get plist :key))) t)))

(defun ema--provider-line (cell)
  (let ((p (cdr cell)))
    (format "%s%s  model %s  api %s  %s  key %s%s"
            (if (eq (car cell) ema-provider) "* " "  ")
            (car cell) (plist-get p :model) (plist-get p :api)
            (plist-get p :url)
            (cond ((null (plist-get p :key)) "not needed")
                  ((ema--has-key-p p) (format "%s (present)" (plist-get p :key)))
                  (t (format "%s (MISSING)" (plist-get p :key))))
            (if (plist-get p :effort) (format "  effort %s" (plist-get p :effort)) ""))))

(ema-deftool ema-providers-list ()
  "Return the provider configurations, one per line; * marks the one in use.
Each line shows the model, the wire format, the URL and whether the key
is present.  A key's value is never shown, and you must never read one."
  (mapconcat #'ema--provider-line ema-providers "\n"))

(defun ema--get-json (url headers)
  "GET URL with HEADERS; return the parsed JSON or signal an error."
  (let* ((url-request-method "GET")
         (url-request-extra-headers
          (mapcar (lambda (h) (cons (car h) (encode-coding-string (cdr h) 'utf-8)))
                  headers))
         (buf (url-retrieve-synchronously (encode-coding-string url 'utf-8) t t 30)))
    (unless buf (error "No answer from %s" url))
    (with-current-buffer buf
      (unwind-protect
          (let ((json (ignore-errors
                        (ema--json-parse
                         (decode-coding-string
                          (buffer-substring-no-properties
                           url-http-end-of-headers (point-max))
                          'utf-8)))))
            (if (and url-http-response-status (>= url-http-response-status 400))
                (error "%s" (ema--error-text json url-http-response-status))
              json))
        (kill-buffer buf)))))

(ema-deftool ema-provider-models (&optional name)
  "Return the model ids that provider NAME (default: current) offers.
The list comes from the provider's own models endpoint, so use it
instead of a model id from memory."
  (let* ((p (ema-provider-plist name))
         (openai (eq (plist-get p :api) 'openai))
         (json (ema--get-json
                (if openai
                    (replace-regexp-in-string "/chat/completions\\'" "/models"
                                              (plist-get p :url))
                  (concat (replace-regexp-in-string "/messages\\'" "/models"
                                                    (plist-get p :url))
                          "?limit=200"))
                (seq-remove (lambda (h) (equal (car h) "content-type"))
                            (if openai (ema--openai-headers p)
                              (ema--anthropic-headers p))))))
    (mapcar (lambda (m) (plist-get m :id)) (plist-get json :data))))

;;;; Test, then switch

(defconst ema--probe-tool
  '(:name "eval" :description "Evaluate Emacs Lisp."
    :input_schema (:type "object"
                   :properties (:code (:type "string"))
                   :required ["code"])))

(defun ema--candidate (name &optional model overrides)
  "Return the plist of provider NAME with MODEL and OVERRIDES applied."
  (let ((p (copy-sequence (ema-provider-plist name))))
    (when (and model (not (string-empty-p model)))
      (setq p (plist-put p :model model)))
    (while overrides
      (setq p (plist-put p (pop overrides) (pop overrides))))
    p))

(defun ema--probe (plist &optional timeout)
  "Make one real call with provider PLIST; return (:ok BOOL :detail STRING :ms N).
The call asks for one tool call, since tool calls are what ema needs."
  (let ((start (float-time)) (reply nil)
        (deadline (+ (float-time) (or timeout 90))))
    (condition-case err
        (progn
          (ema-llm-request
           "You are a connection test. Do exactly what the user asks."
           (list (list :role "user"
                       :content "Call the eval tool once with code (+ 1 1)."))
           (list ema--probe-tool)
           (lambda (r) (setq reply r))
           nil plist)
          (while (and (null reply) (< (float-time) deadline))
            (accept-process-output nil 0.1))
          (let ((ms (round (* 1000 (- (float-time) start)))))
            (cond
             ((null reply) (list :ok nil :ms ms :detail "no answer in time"))
             ((plist-get reply :error)
              (list :ok nil :ms ms :detail (plist-get reply :error)))
             ((seq-some (lambda (b) (equal (plist-get b :type) "tool_use"))
                        (plist-get reply :content))
              (list :ok t :ms ms :detail "answered with a tool call"))
             (t (list :ok nil :ms ms
                      :detail "answered, but made no tool call")))))
      (error (list :ok nil :ms 0
                   :detail (car (split-string (error-message-string err) "[\r\n]")))))))

(ema-deftool ema-provider-test (name &optional model &rest overrides)
  "Test provider NAME with MODEL without switching to it.
Makes one real call through a separate adapter instance and checks that
a tool call comes back.  OVERRIDES are plist pairs for the trial, such
as :effort \"high\" or :max-tokens 8000.  Returns (:ok BOOL :ms N
:detail STRING).  The running conversation is not affected."
  (ema--probe (ema--candidate name model overrides)))

(ema-deftool ema-provider-add (name &rest plist)
  "Add or replace provider configuration NAME (a symbol) with PLIST.
Keys: :api (`anthropic' or `openai', the wire format), :url (the full
messages or chat/completions URL), :model, :key (a secret NAME, never a
value; nil for a local server), :effort, :max-tokens.  The configuration
is saved but not used: test it, then switch."
  (unless (memq (plist-get plist :api) '(anthropic openai))
    (error ":api must be anthropic or openai"))
  (unless (and (plist-get plist :url) (plist-get plist :model))
    (error ":url and :model are required"))
  (setf (alist-get name ema-providers) plist)
  (ema-save-config)
  (ema--provider-line (assq name ema-providers)))

(ema-deftool ema-provider-switch (name &optional model &rest overrides)
  "Test provider NAME with MODEL and OVERRIDES; switch to it when the test passes.
On a failed test nothing changes and the reason comes back.  On success
the configuration is saved, and the conversation continues on the new
model from the next call on."
  (let* ((plist (ema--candidate name model overrides))
         (result (ema--probe plist)))
    (if (not (plist-get result :ok))
        (format "NOT switched: %s/%s failed the test: %s"
                name (plist-get plist :model) (plist-get result :detail))
      (setf (alist-get name ema-providers) plist)
      (setq ema-provider name)
      (ema-save-config)
      (force-mode-line-update t)
      (format "switched to %s/%s (test passed in %d ms)"
              name (plist-get plist :model) (plist-get result :ms)))))

(defun ema--annotated-read (prompt rows)
  "Read one of ROWS ((LABEL . NOTE)...) with NOTE as its annotation."
  (let ((completion-extra-properties
         (list :annotation-function
               (lambda (c) (when-let* ((n (cdr (assoc c rows))))
                             (concat "   " n))))))
    (completing-read prompt (mapcar #'car rows) nil t)))

(ema-deftool ema-provider-propose (options &optional why)
  "Offer model configurations to the user; test and switch to the one they pick.
OPTIONS is a list of (NAME MODEL NOTE): a provider symbol, a model id
and one line on why that option (speed, cost, quality).  WHY is the
reason for the proposal, shown in the prompt.  The user picks in the
minibuffer or quits with C-g; the pick is tested first.  Returns the
result of `ema-provider-switch', or \"declined\"."
  (let* ((rows (mapcar (lambda (o)
                         (cons (format "%s/%s" (nth 0 o) (nth 1 o))
                               (or (nth 2 o) "")))
                       options))
         (pick (condition-case nil
                   (ema--annotated-read
                    (format "%s — use model: "
                            (string-trim-right (or why "ema proposes") "[.: ]+"))
                    rows)
                 (quit nil)))
         (option (and pick (nth (cl-position pick rows :key #'car :test #'equal)
                                options))))
    (if (null option)
        "declined"
      (message "ema: testing %s…" pick)
      (ema-provider-switch (nth 0 option) (nth 1 option)))))

;;;###autoload
(defun ema-switch-provider ()
  "Pick a provider and a model, test them, and switch when the test passes."
  (interactive)
  (let* ((name (intern
                (ema--annotated-read
                 "Provider: "
                 (mapcar (lambda (cell)
                           (cons (symbol-name (car cell))
                                 (format "%s  %s" (plist-get (cdr cell) :model)
                                         (if (ema--has-key-p (cdr cell))
                                             "" "(key missing)"))))
                         ema-providers))))
         (current (plist-get (ema-provider-plist name) :model))
         (models (progn (message "ema: reading the model list…")
                        (condition-case nil (ema-provider-models name)
                          (error nil))))
         (model (completing-read (format "Model (default %s): " current)
                                 models nil nil nil nil current)))
    (message "ema: testing %s/%s…" name model)
    (message "ema: %s" (ema-provider-switch name model))))

;;;; What the agent is told about itself

(defun ema-self-description ()
  "Return the prompt section that describes ema's own parts."
  (format "
## Yourself

You are an Emacs package and you can inspect and change yourself.

- Source: %s — ema.el (the eval cell, the chat buffer, the loop),
  ema-llm.el (provider adapters, secrets, HTTP), ema-tools.el (tools),
  ema-self.el (these self tools), skills/core.md (this prompt). Read
  them with `ema-buffer-text' or `ema-outline' when asked how you work.
- State: %s — tools/ (stored tools), skills/ (stored skills),
  config.eld (provider configurations).
- The provider and model in use: `(ema-providers-list)`, the line with *.
- Limits are variables: `ema-max-turns', `ema-digest-limit',
  `ema-digest-full-limit', `ema-request-timeout'.

To change the model or its configuration, never set `ema-provider' or
`ema-providers' yourself:

1. `(ema-providers-list)` shows the configurations; `(ema-provider-models
   'NAME)` lists the real model ids. Do not use a model id from memory.
2. When the user has not named an exact model, offer two to four options
   with `(ema-provider-propose '((NAME \"MODEL\" \"why\") …) \"reason\")`:
   the user picks in the Emacs UI, and the pick is tested before the
   switch.
3. When they named one, `(ema-provider-switch 'NAME \"MODEL\")`: it
   tests the configuration through a separate adapter instance and
   switches only when the test passes. `ema-provider-test' tests without
   a switch; `ema-provider-add' defines a new endpoint.

A switch takes effect at your next model call, so report the result in
the same turn. Secrets are names (`llm.key.x'): never read, print or ask
for a key's value; a missing key is the user's to add to the secrets
file.
"
          (abbreviate-file-name ema-source-directory)
          (abbreviate-file-name ema-directory)))

;;;; Restart

(defconst ema--source-files '("ema-llm" "ema-tools" "ema-self" "ema" "ema-actions")
  "Source files of ema in dependency order, leaves first.")

(defun ema-restart ()
  "Reload all of ema's source files, in dependency order.
Meant for development.  Loads the .el files, never stale .elc.  Values
of `defvar's (keymaps among them) are kept; only the code is replaced."
  (interactive)
  (let ((chat (get-buffer "*ema*")))
    (when (and chat (buffer-local-value 'ema--busy chat)
               (not (yes-or-no-p "ema is working; reload anyway? ")))
      (user-error "ema-restart cancelled")))
  (dolist (name ema--source-files)
    (load (expand-file-name (concat name ".el") ema-source-directory)
          nil 'nomessage 'nosuffix))
  (message "ema reloaded: %s" (mapconcat #'identity ema--source-files " ")))

(provide 'ema-self)
;;; ema-self.el ends here
