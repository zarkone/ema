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

;;;; Providers and models: inspect, test, switch

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

;;; Test, then switch

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

You are an Emacs package that runs from source, and you can inspect and
change yourself.

- Source: %s, a git checkout. `(ema-self-files)` lists the files and
  what each holds. Before you change them, read `(ema-skill \"self\")`.
- State: %s — tools/ (stored tools), skills/ (stored skills),
  config.eld (provider configurations).
- Model: `(ema-providers-list)` shows the provider and model in use.
  Never set `ema-provider' or `ema-providers' yourself, and never use a
  model id from memory: read `(ema-skill \"providers\")` first.
- Secrets are names (`llm.key.x'). Never read, print or ask for a key's
  value, and never open or decrypt the auth-source file; a missing key
  goes through `(ema-skill \"secrets\")`.
- Limits are variables: `ema-max-turns', `ema-digest-limit',
  `ema-digest-full-limit', `ema-request-timeout'.
"
          (abbreviate-file-name ema-source-directory)
          (abbreviate-file-name ema-directory)))

;;;; Secrets: status and entry, never values

(ema-deftool ema-secrets-status ()
  "Return the state of the secret store, without any secret value.
Lines: the files in `auth-sources' and whether each exists, whether gpg
is installed and has a secret key, and for each provider key whether it
is present.  The check of a key can make Emacs ask the user for their
GPG passphrase."
  (let ((files (mapcar (lambda (s) (if (stringp s) s (plist-get s :source)))
                       auth-sources)))
    (concat
     (mapconcat (lambda (f)
                  (format "auth-source %s: %s" f
                          (cond ((not (stringp f)) "not a file")
                                ((file-exists-p f) "exists")
                                (t "does not exist yet"))))
                files "\n")
     (format "\ngpg: %s"
             (if (executable-find "gpg")
                 (format "installed, %d secret key(s)"
                         (with-temp-buffer
                           (ignore-errors
                             (process-file "gpg" nil t nil "--list-secret-keys" "--with-colons"))
                           (how-many "^sec:" (point-min) (point-max))))
               "not installed"))
     (format "\nnew secrets go to: %s"
             (condition-case err (ema--secret-store-file)
               (error (error-message-string err))))
     "\n"
     (mapconcat (lambda (name)
                  (format "%s: %s" name
                          (if (ignore-errors (funcall ema-secret-function name))
                              "present" "missing")))
                (ema-secret-names) "\n"))))

(ema-deftool ema-secret-ask (name)
  "Ask the user to type secret NAME into the minibuffer, then save it.
The value is hidden and you never see it.  NAME is a provider's key
name such as \"llm.key.anthropic\".  Returns \"saved in FILE\" or
\"cancelled\".  Tell the user in the chat first what you will ask for
and where they get the key."
  (unless (member name (ema-secret-names))
    (error "No provider uses %s; the names are %s" name (ema-secret-names)))
  (condition-case nil
      (let ((value (read-passwd (format "ema asks for %s (not shown, C-g cancels): " name))))
        (if (string-empty-p value)
            "cancelled"
          (unwind-protect
              (format "saved in %s" (abbreviate-file-name (ema-secret-store name value)))
            (clear-string value))))
    (quit "cancelled")))

;;;; Your own source: files, check, reload

(defconst ema--source-files
  '("ema-llm" "ema-tools" "ema-history" "ema-self" "ema-org" "ema" "ema-actions")
  "Source files of ema in dependency order, leaves first.")

(ema-deftool ema-self-files ()
  "Return ema's own source files, one per line: \"name — what it holds\".
The files are in `ema-source-directory'.  The list is read from the
folder and from the first line of each file, so it is current."
  (mapconcat
   (lambda (file)
     (format "%s — %s" (file-name-nondirectory file)
             (ema--file-summary file)))
   (append (ema--self-paths)
           ;; the folder, not a list, says which other files exist
           (seq-difference (directory-files ema-source-directory t "\\`[^.#].*\\.el\\'")
                           (ema--self-paths))
           (directory-files (expand-file-name "skills" ema-source-directory) t "\\.md\\'"))
   "\n"))

(defvar ema--self-check-time nil
  "When the last `ema-self-check' started.")

(defun ema--self-paths ()
  (mapcar (lambda (n) (expand-file-name (concat n ".el") ema-source-directory))
          ema--source-files))

(ema-deftool ema-self-check ()
  "Compile ema's source and run its tests in a separate Emacs process.
This is the gate before `ema-self-reload': a broken file fails here and
not in the session you run in.  It returns at once; read the outcome
with `(ema-run-result \"self-check\" 30)`.  Save the source buffers
first: the check reads the files."
  (dolist (file (ema--self-paths))
    (let ((buf (find-buffer-visiting file)))
      (when (and buf (buffer-modified-p buf))
        (error "%s has unsaved changes; save it first" (buffer-name buf)))))
  (setq ema--self-check-time (current-time))
  (ema-run "make compile && make test" ema-source-directory "self-check"))

(ema-deftool ema-self-reload ()
  "Load ema's source files into this session, after a passed `ema-self-check'.
Refuses when no check ran, when it still runs or failed, or when a
source file changed after the check started.  The new code is live from
the next cell; values of variables (keymaps among them) are kept."
  (let ((result (and ema--self-check-time
                     (get-buffer (ema--run-buffer-name "self-check"))
                     (ema-run-result "self-check"))))
    (unless (equal (plist-get result :status) "finished")
      (error "No passed check: run (ema-self-check) and read (ema-run-result \"self-check\" 30); status: %s"
             (or (plist-get result :status) "none")))
    (dolist (file (ema--self-paths))
      (when (time-less-p ema--self-check-time
                         (file-attribute-modification-time (file-attributes file)))
        (error "%s changed after the check; run (ema-self-check) again"
               (file-name-nondirectory file))))
    (dolist (file (ema--self-paths))
      (load file nil 'nomessage 'nosuffix))
    (format "reloaded: %s" (mapconcat #'identity ema--source-files " "))))

(defun ema-restart ()
  "Reload all of ema's source files, in dependency order.
Meant for development.  Loads the .el files, never stale .elc.  Values
of `defvar's (keymaps among them) are kept; only the code is replaced."
  (interactive)
  (when (and (seq-some (lambda (b) (buffer-local-value 'ema--busy b))
                       (seq-filter (lambda (b) (local-variable-p 'ema--busy b))
                                   (buffer-list)))
             (not (yes-or-no-p "ema is working; reload anyway? ")))
    (user-error "ema-restart cancelled"))
  (dolist (name ema--source-files)
    (load (expand-file-name (concat name ".el") ema-source-directory)
          nil 'nomessage 'nosuffix))
  (message "ema reloaded: %s" (mapconcat #'identity ema--source-files " ")))

(provide 'ema-self)
;;; ema-self.el ends here
