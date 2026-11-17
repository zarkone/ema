;;; ema-self.el --- The agent's knowledge of itself -*- lexical-binding: t -*-

;; Copyright (C) 2026 Anatolii Smolianinov
;; Author: Anatolii Smolianinov <zarkonesmall@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of ema.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tools with which the agent inspects and changes its own setup: the
;; provider configurations, the model in use, its source files.
;;
;; A provider change is never blind.  `ema-provider-test' makes a real
;; call through an independent adapter instance (`ema-llm-request' with
;; an explicit provider plist), and the switch happens only when that
;; call returns a working tool call.
;;
;; The file, top to bottom:
;;
;;   Saved configuration   config.eld: the provider table
;;   Providers and models  list, test, switch (tools and commands)
;;   What the agent is told about itself   a section of the prompt
;;   Secrets               status and entry, never values
;;   Your own source       files, the check, the reload

;;; Code:

(require 'ema-llm)
(require 'ema-tools)

(defvar url-http-response-status)
(declare-function ema--project-root "ema-chat")
(declare-function ema--busy-chat "ema-chat")
(declare-function ema-config-save "ema-history")

(defvar ema-source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of ema's own source files.")

;;;; Saved configuration

;; config.eld holds the provider table and the fallback provider.  Which
;; provider a project uses is not here: it is a row in the history
;; database (see `ema-current-config').

(defun ema-save-config ()
  "Save the provider configurations and the current provider."
  (ema--write-state "config.eld"
                    (list :provider ema-provider :providers ema-providers)))

(defun ema-load-config ()
  "Load the saved provider configurations over the defaults."
  (condition-case err
      (when-let* ((cfg (ema--read-state "config.eld")))
        (dolist (cell (plist-get cfg :providers))
          (setf (alist-get (car cell) ema-providers) (cdr cell)))
        (when (alist-get (plist-get cfg :provider) ema-providers)
          (setq ema-provider (plist-get cfg :provider))))
    (error (message "ema: config not loaded: %s" (error-message-string err)))))

;;;; Providers and models: inspect, test, switch

(defun ema--has-key-p (plist)
  "Non-nil when provider PLIST needs no key or its key can be read."
  (or (null (plist-get plist :key))
      (and (ignore-errors (funcall ema-secret-function (plist-get plist :key))) t)))

(defun ema--provider-line (cell)
  "Return one line on provider CELL, an element of `ema-providers'."
  (let* ((current (eq (car cell) (ema-current-provider)))
         ;; the one in use shows the model and options of this project
         (p (if current (plist-get (ema-current-config) :plist) (cdr cell))))
    (format "%s%s  model %s  api %s  %s  key %s%s"
            (if current "* " "  ")
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
         (url-request-extra-headers headers)
         (buf (url-retrieve-synchronously (encode-coding-string url 'utf-8) t t 30)))
    (unless buf (error "No answer from %s" url))
    (with-current-buffer buf
      (unwind-protect
          (let ((json (ema--response-json)))
            (if (and url-http-response-status (>= url-http-response-status 400))
                (error "%s" (ema--error-text json url-http-response-status))
              json))
        (kill-buffer buf)))))

(defun ema--models-url (p)
  "Return the URL of the models endpoint of provider plist P."
  (if (eq (plist-get p :api) 'openai)
      (replace-regexp-in-string "/chat/completions\\'" "/models"
                                (plist-get p :url))
    (concat (replace-regexp-in-string "/messages\\'" "/models"
                                      (plist-get p :url))
            "?limit=200")))

(ema-deftool ema-provider-models (&optional name)
  "Return the model ids that provider NAME (default: current) offers.
The list comes from the provider's own models endpoint, so use it
instead of a model id from memory."
  (let* ((p (ema-provider-plist name))
         (json (ema--get-json
                (ema--models-url p)
                (seq-remove (lambda (h) (equal (car h) "content-type"))
                            (ema--request-headers p)))))
    (mapcar (lambda (m) (plist-get m :id)) (plist-get json :data))))

;;; Test a candidate

(defconst ema--probe-tool
  '(:name "eval" :description "Evaluate Emacs Lisp."
    :input_schema (:type "object"
                   :properties (:code (:type "string"))
                   :required ["code"])))

(defun ema--candidate (name &optional model overrides)
  "Return the plist of provider NAME with MODEL and OVERRIDES applied."
  (ema--plist-merge (ema-provider-plist name)
                    (append (and model (not (string-empty-p model))
                                 (list :model model))
                            overrides)))

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

;;; Switch: only after a passed test

(defun ema--switch (name model overrides scope)
  "Test provider NAME with MODEL and OVERRIDES; store it for SCOPE when it passes.
SCOPE is a project root or `ema-default-config-key'.  Return a message."
  (let* ((plist (ema--candidate name model overrides))
         (result (ema--probe plist)))
    (if (plist-get result :ok)
        (ema--store-switch name plist overrides scope (plist-get result :ms))
      (format "NOT switched: %s/%s failed the test: %s"
              name (plist-get plist :model) (plist-get result :detail)))))

(defun ema--store-switch (name plist overrides scope ms)
  "Store the tested provider NAME for SCOPE; return a message.
PLIST is the plist of the provider with the model and OVERRIDES applied.
MS is how long the test took."
  (let* ((default (equal scope ema-default-config-key))
         (model (plist-get plist :model))
         (own (plist-get (ema-provider-plist name) :model))
         ;; a model that is the provider's own is stored as nil
         (stored (ema-config-save scope name
                                  (and (not (equal model own)) model)
                                  overrides)))
    (cond
     (stored
      (force-mode-line-update t)
      (format "switched %s to %s/%s (test passed in %d ms)%s"
              (if default "the default"
                (format "this project (%s)" (abbreviate-file-name scope)))
              name model ms
              (ema--switch-caveat scope default)))
     ;; without the database only the global choice can be kept
     (default
      (setf (alist-get name ema-providers) plist)
      (setq ema-provider name)
      (ema-save-config)
      (force-mode-line-update t)
      (format "switched the default to %s/%s (test passed in %d ms)" name model ms))
     (t "NOT switched: the history database is off, and a project setting is kept there"))))

(defun ema--switch-caveat (scope default)
  "Return a note when the switch stored for SCOPE has no effect here, or \"\".
DEFAULT is non-nil when SCOPE is the default row."
  (let ((source (plist-get (ema-current-config (and (not default) scope))
                           :source)))
    (cond
     ((eq source 'dir-locals)
      "; but .dir-locals.el overrides it here, so it has no effect in this project")
     ((and default (eq source 'project))
      "; this project keeps its own setting")
     (t ""))))

(ema-deftool ema-provider-switch (name &optional model &rest overrides)
  "Test provider NAME with MODEL and OVERRIDES; switch to it when the test passes.
In a project the switch is for that project only; outside one it is for
the default, which every project without its own setting uses.  The
reply says which one it was, and when .dir-locals.el overrides it.  On
a failed test nothing changes and the reason comes back.  On success
the configuration is stored, and the conversation continues on the new
model from the next call on."
  (ema--switch name model overrides
               (or (ema--project-root) ema-default-config-key)))

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

(defun ema--read-switch ()
  "Read a provider and a model in the minibuffer; return (NAME MODEL)."
  (let* ((name (intern
                (ema--annotated-read
                 "Provider: "
                 (mapcar (lambda (cell)
                           (cons (symbol-name (car cell))
                                 (format "%s  %s" (plist-get (cdr cell) :model)
                                         (if (ema--has-key-p (cdr cell))
                                             "" "(key missing)"))))
                         ema-providers))))
         (current (if (eq name (ema-current-provider))
                      (plist-get (ema-current-config) :model)
                    (plist-get (ema-provider-plist name) :model)))
         (models (progn (message "ema: reading the model list…")
                        (condition-case nil (ema-provider-models name)
                          (error nil))))
         (model (completing-read (format "Model (default %s): " current)
                                 models nil nil nil nil current)))
    (message "ema: testing %s/%s…" name model)
    (list name model)))

;;;###autoload
(defun ema-switch-provider ()
  "Pick a provider and a model, test them, and switch when the test passes.
In a project the switch is for that project; outside one it is for the
default.  The message says which.  `ema-switch-default-provider' always
sets the default."
  (interactive)
  (message "ema: %s" (apply #'ema-provider-switch (ema--read-switch))))

;;;###autoload
(defun ema-switch-default-provider ()
  "Pick the default provider and model, which projects without their own use."
  (interactive)
  (pcase-let ((`(,name ,model) (ema--read-switch)))
    (message "ema: %s" (ema--switch name model nil ema-default-config-key))))

;;;; What the agent is told about itself

(defun ema-self-description ()
  "Return the prompt section that describes ema's own parts."
  (format "
## Yourself

You are an Emacs package that runs from source; you can inspect and
change yourself.

- Source: %s, a git checkout; `(ema-self-files)` lists it. Before you
  change it, read `(ema-skill \"self\")`.
- State: %s — tools/, skills/, config.eld (provider configurations).
- Model: never set `ema-provider' or `ema-providers' yourself and never
  use a model id from memory; read `(ema-skill \"providers\")`.
- Secrets are names (`llm.key.x'). Never read, print or ask for a key's
  value, and never open or decrypt the auth-source file; for a missing
  key read `(ema-skill \"secrets\")`.
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
  (let ((files (ema--auth-source-files)))
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
      (let ((file (ema--secret-read-and-store
                   name (format "ema asks for %s (not shown, C-g cancels): " name))))
        (if file (format "saved in %s" file) "cancelled"))
    (quit "cancelled")))

;;;; Your own source: files, check, reload

(defconst ema--source-files
  '("ema-llm" "ema-tools" "ema-review" "ema-history" "ema-self" "ema-org"
    "ema-cell" "ema-chat" "ema" "ema-actions")
  "Source files of ema in dependency order, leaves first.
The Makefile has the same list for `make compile'.")

(defun ema--self-paths ()
  "Return the paths of `ema--source-files'."
  (mapcar (lambda (n) (expand-file-name (concat n ".el") ema-source-directory))
          ema--source-files))

(defun ema--self-load ()
  "Load every source file of ema, in dependency order; return their names.
The .el files are loaded, never a stale .elc."
  (dolist (file (ema--self-paths))
    (load file nil 'nomessage 'nosuffix))
  (string-join ema--source-files " "))

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
    (format "reloaded: %s" (ema--self-load))))

(defun ema-restart ()
  "Reload all of ema's source files, in dependency order.
Meant for development.  Loads the .el files, never stale .elc.  Values
of `defvar's (keymaps among them) are kept; only the code is replaced."
  (interactive)
  (when (and (fboundp 'ema--busy-chat) (ema--busy-chat)
             (not (yes-or-no-p "ema is working; reload anyway? ")))
    (user-error "ema-restart cancelled"))
  (message "ema reloaded: %s" (ema--self-load)))

(provide 'ema-self)
;;; ema-self.el ends here
