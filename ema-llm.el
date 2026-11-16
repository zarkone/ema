;;; ema-llm.el --- Providers and secrets for ema -*- lexical-binding: t -*-

;;; Commentary:

;; One entry point: `ema-llm-request'.  The conversation is kept in one
;; neutral shape (the Anthropic Messages shape, as plists with vectors);
;; each provider API converts it on the way out and back.  That is what
;; makes a provider switch possible in the middle of a conversation.
;;
;; Secrets go through `ema-secret' only; the default source is auth-source.
;;
;; The file, top to bottom:
;;
;;   Providers            the table `ema-providers' and the fallback choice
;;   Secrets              read a key, save a key
;;   The provider in use  `ema-current-config': which provider and model a
;;                        project gets
;;   JSON                 encode and parse
;;   Wire formats         Anthropic and OpenAI-compatible: body, headers,
;;                        parse
;;   Transport            `ema-llm-request': HTTP, retries, the timeout

;;; Code:

(require 'url)
(require 'url-http)
(require 'json)
(require 'subr-x)
(require 'seq)
(require 'auth-source)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

;;;; Providers

(defvar ema-providers
  '((anthropic  :api anthropic :model "claude-opus-5-5"
                :url "https://api.anthropic.com/v1/messages"
                :key "llm.key.anthropic")
    (openrouter :api openai :model "anthropic/claude-opus-5.5"
                :url "https://openrouter.ai/api/v1/chat/completions"
                :key "llm.key.openrouter")
    (openai     :api openai :model "gpt-5"
                :url "https://api.openai.com/v1/chat/completions"
                :key "llm.key.openai"))
  "Alist of (NAME . PLIST).  PLIST keys: :api (`anthropic' or `openai',
the wire format), :url, :model, :key (a name for `ema-secret'; nil for
a keyless local server), :effort (Anthropic only), :max-tokens.")

(defvar ema-provider 'anthropic
  "The fallback provider, a key of `ema-providers'.
The provider in use is resolved per project by `ema-current-config':
.dir-locals.el, then the project's stored row, then the default row,
then this variable.  Set it in .dir-locals.el to choose for a project.")

(defvar ema-model nil
  "Model override for the provider in use; nil means the provider's own.
Meant for .dir-locals.el, next to `ema-provider'.")

(defconst ema-default-config-key "default"
  "The key of the global row among the stored configurations.
A project's key is its absolute root path, so the two never collide.")

(defvar ema-config-store-function nil
  "Function of one argument KEY that returns a stored configuration, or nil.
KEY is a project root or `ema-default-config-key'.  The result is a
plist (:provider SYMBOL :model STRING-OR-NIL :options PLIST).
ema-history.el sets it to read the database.")

;;;; Secrets

(defvar ema-secret-function #'ema-secret-from-auth-source
  "Function of one argument NAME that returns the secret or nil.
Replace it to read from another store (pass, a keyring).")

(defcustom ema-secret-store-file nil
  "The file where `ema-secret-set' saves a secret.
nil means the first GPG-encrypted file in `auth-sources'.  A file that
does not end in .gpg holds the secret as plain text."
  :type '(choice (const nil) file) :group 'ema)

(defun ema-secret-from-auth-source (name)
  "Return secret NAME from `auth-sources', else from the environment.
The entry is the one whose host (\"machine\") is NAME:
  machine llm.key.anthropic login ema password VALUE
The environment name is NAME upcased with dots as underscores."
  (or (auth-source-pick-first-password :host name)
      (getenv (upcase (string-replace "." "_" name)))))

(defun ema-secret (name)
  "Return secret NAME, or signal an error that names it."
  (or (funcall ema-secret-function name)
      (error "ema: no secret %s. Add it with M-x ema-secret-set" name)))

(defun ema--auth-source-files ()
  "Return the entries of `auth-sources' as file names.
An entry that names no file comes back as it is, not as a string."
  (mapcar (lambda (source)
            (if (stringp source) source (plist-get source :source)))
          auth-sources))

(defun ema--secret-store-file ()
  "Return the file that receives a new secret, or signal an error."
  (or ema-secret-store-file
      (seq-find (lambda (f) (and (stringp f) (string-suffix-p ".gpg" f)))
                (ema--auth-source-files))
      (error "No .gpg file in `auth-sources': add \"~/.authinfo.gpg\" to it first")))

(defun ema-secret-store (name value)
  "Save VALUE as secret NAME in the auth-source file; return the file.
An older entry for NAME in that file is replaced by hand: this adds an
entry and does not remove one."
  (let* ((file (ema--secret-store-file))
         (auth-sources (list file))
         (found (car (auth-source-search :host name :user "ema" :secret value
                                         :max 1 :create t)))
         (save (plist-get found :save-function)))
    (when (functionp save) (funcall save))
    (auth-source-forget-all-cached)
    file))

(defun ema-secret-names ()
  "Return the secret names that the providers use."
  (delete-dups (delq nil (mapcar (lambda (cell) (plist-get (cdr cell) :key))
                                 ema-providers))))

(defun ema-secret-set (name)
  "Read the value of secret NAME in the minibuffer and save it.
The value is not echoed and not kept in a buffer.  It goes to the
GPG-encrypted file in `auth-sources' (see `ema-secret-store-file')."
  (interactive
   (list (completing-read "Secret name: " (ema-secret-names) nil nil nil nil
                          (car (ema-secret-names)))))
  (let ((file (ema--secret-read-and-store
               name (format "Value of %s (not shown): " name))))
    (unless file (user-error "Empty value; nothing saved"))
    (message "ema: %s saved in %s" name file)))

(defun ema--secret-read-and-store (name prompt)
  "Read the value of secret NAME with PROMPT, hidden, and save it.
Return the abbreviated name of the file, or nil when the user typed
nothing.  The value is cleared from memory after the save."
  (let ((value (read-passwd prompt)))
    (unwind-protect
        (unless (string-empty-p value)
          (abbreviate-file-name (ema-secret-store name value)))
      (clear-string value))))

;;;; The provider in use: .dir-locals.el, the project, the default

;; A choice has three stored sources and one fallback.  Most specific
;; first:
;;
;;   1. .dir-locals.el of the project (`ema-provider', `ema-model')
;;   2. the row of the project        } in the history database, read
;;   3. the default row               } through `ema-config-store-function'
;;   4. the variable `ema-provider'
;;
;; ema-self.el has the commands and tools that test and store a choice.

(defvar ema-directory)
(declare-function ema--project-root "ema-chat")

(defvar ema--config-cache nil
  "Alist ((ROOT DIRECTORY PROVIDER) . (TIME . CHOICE)) of resolved choices.
The mode line asks on every redisplay; this keeps it from reading the
database and .dir-locals.el each time.")

(defconst ema--config-cache-seconds 5
  "How long a resolved choice is kept; an edit of .dir-locals.el shows up then.")

(defun ema-config-flush ()
  "Forget the resolved choices, after a change of a stored configuration."
  (setq ema--config-cache nil))

(defun ema--dir-local-values (root)
  "Return the ema variables that .dir-locals.el sets for ROOT, as an alist.
Nothing is applied: the values are only read, and the caller checks them."
  (when (and root enable-local-variables)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root))
      (let ((enable-local-variables :all))
        (ignore-errors (hack-dir-local-variables)))
      (seq-filter (lambda (c) (memq (car c) '(ema-provider ema-model)))
                  dir-local-variables-alist))))

(defun ema--stored-config (key)
  "Return the stored configuration for KEY when its provider still exists."
  (when (and key ema-config-store-function)
    (let ((c (ignore-errors (funcall ema-config-store-function key))))
      (and c (alist-get (plist-get c :provider) ema-providers) c))))

(defun ema--config-choice (root)
  "Return (:provider :model :options :source) for project ROOT, uncached."
  (let* ((dl (ema--dir-local-values root))
         (dl-provider (let ((p (alist-get 'ema-provider dl)))
                        (and p (alist-get p ema-providers) p)))
         (dl-model (alist-get 'ema-model dl))
         (project (and root (ema--stored-config root)))
         (default (ema--stored-config ema-default-config-key))
         (base (or project default))
         (provider (or dl-provider (plist-get base :provider) ema-provider))
         ;; a stored model and options belong to the stored provider only
         (same (eq provider (plist-get base :provider))))
    (list :provider provider
          :model (or (and (stringp dl-model) dl-model)
                     (and same (plist-get base :model)))
          :options (and same (plist-get base :options))
          :source (cond ((or dl-provider dl-model) 'dir-locals)
                        (project 'project)
                        (default 'default)
                        (t 'variable)))))

(defun ema-current-config (&optional root)
  "Return the provider configuration in use for project ROOT.
ROOT defaults to the project of the current buffer.  The order, most
specific first: .dir-locals.el (`ema-provider', `ema-model'), the row of
the project, the default row, the variable `ema-provider'.  A plist:
:provider, :model (the model that will be used), :options (overrides
such as :effort), :plist (the provider's plist with both applied, ready
for a request) and :source (`dir-locals', `project', `default' or
`variable')."
  (let* ((root (or root (and (fboundp 'ema--project-root) (ema--project-root))))
         (choice (ema--config-choice-cached root))
         (model (plist-get choice :model))
         (options (plist-get choice :options))
         (plist (ema--plist-merge (ema-provider-plist (plist-get choice :provider))
                                  (append (and model (list :model model)) options))))
    (list :provider (plist-get choice :provider)
          :model (plist-get plist :model)
          :options options
          :source (plist-get choice :source)
          :plist plist)))

(defun ema--config-choice-cached (root)
  "Return `ema--config-choice' for ROOT, at most `ema--config-cache-seconds' old."
  (let* ((key (list root (bound-and-true-p ema-directory) ema-provider))
         (hit (assoc key ema--config-cache)))
    (if (and hit (< (- (float-time) (cadr hit)) ema--config-cache-seconds))
        (cddr hit)
      (let ((choice (ema--config-choice root)))
        (setf (alist-get key ema--config-cache nil nil #'equal)
              (cons (float-time) choice))
        choice))))

(defun ema--plist-merge (plist overrides)
  "Return a copy of PLIST with the pairs of plist OVERRIDES put over it."
  (let ((out (copy-sequence plist)))
    (while overrides
      (setq out (plist-put out (pop overrides) (pop overrides))))
    out))

(defun ema-current-provider ()
  "Return the name of the provider in use for the current project."
  (plist-get (ema-current-config) :provider))

(defun ema-provider-plist (&optional name)
  "Return the plist of provider NAME.
Without NAME it is the provider in use for the current project, with
its model and options applied (see `ema-current-config')."
  (if name
      (or (alist-get name ema-providers)
          (error "ema: unknown provider %s" name))
    (plist-get (ema-current-config) :plist)))

;;;; JSON

(defun ema--json-encode (obj)
  "Serialize OBJ (plists, vectors) to a unibyte UTF-8 string."
  (json-serialize obj :null-object :null :false-object :false))

(defun ema--json-parse (string)
  "Parse STRING (decoded text) to plists and vectors."
  (json-parse-string string :object-type 'plist :array-type 'array
                     :null-object :null :false-object :false))

;;;; Anthropic wire format

(defun ema--anthropic-body (p system messages tools)
  "Build the request body for provider plist P."
  (let ((body (list :model (plist-get p :model)
                    :max_tokens (or (plist-get p :max-tokens) 16000)
                    :system system
                    :messages (vconcat messages)
                    :tools (vconcat tools)
                    :cache_control '(:type "ephemeral"))))
    (when (plist-get p :effort)
      (setq body (plist-put body :output_config
                            (list :effort (plist-get p :effort)))))
    body))

(defun ema--anthropic-headers (p)
  "Build the request headers for provider plist P."
  `(("content-type" . "application/json")
    ("anthropic-version" . "2023-06-01")
    ,@(when (plist-get p :key)
        `(("x-api-key" . ,(ema-secret (plist-get p :key)))))))

(defun ema--anthropic-parse (json)
  "Turn response JSON into the neutral reply plist."
  (let ((u (plist-get json :usage)))
    (list :content (plist-get json :content)
          :stop (plist-get json :stop_reason)
          :usage (list :in (+ (or (plist-get u :input_tokens) 0)
                              (or (plist-get u :cache_creation_input_tokens) 0))
                       :cached (or (plist-get u :cache_read_input_tokens) 0)
                       :out (or (plist-get u :output_tokens) 0)))))

;;;; OpenAI-compatible wire format

(defun ema--blocks (content)
  "Return CONTENT as a list of blocks; a string becomes one text block."
  (if (stringp content)
      (list (list :type "text" :text content))
    (append content nil)))

(defun ema--openai-messages (system messages)
  "Convert neutral MESSAGES plus SYSTEM to chat-completions messages."
  (let ((out (list (list :role "system" :content system))))
    (dolist (m messages)
      (let ((role (plist-get m :role)) (text "") calls)
        (dolist (b (ema--blocks (plist-get m :content)))
          (pcase (plist-get b :type)
            ("text" (setq text (concat text (plist-get b :text))))
            ("tool_use"
             (push (list :id (plist-get b :id) :type "function"
                         :function
                         (list :name (plist-get b :name)
                               :arguments (decode-coding-string
                                           (ema--json-encode (plist-get b :input))
                                           'utf-8)))
                   calls))
            ("tool_result"
             (push (list :role "tool" :tool_call_id (plist-get b :tool_use_id)
                         :content (plist-get b :content))
                   out))))
        ;; thinking blocks belong to the provider that wrote them: dropped
        (cond (calls
               (push (list :role role :content text
                           :tool_calls (vconcat (nreverse calls)))
                     out))
              ((not (string-empty-p text))
               (push (list :role role :content text) out)))))
    (vconcat (nreverse out))))

(defun ema--openai-body (p system messages tools)
  "Build the chat-completions body for provider plist P."
  (list :model (plist-get p :model)
        :messages (ema--openai-messages system messages)
        :tools (vconcat
                (mapcar (lambda (tool)
                          (list :type "function"
                                :function
                                (list :name (plist-get tool :name)
                                      :description (plist-get tool :description)
                                      :parameters (plist-get tool :input_schema))))
                        tools))))

(defun ema--openai-headers (p)
  "Build the request headers for provider plist P."
  `(("content-type" . "application/json")
    ,@(when (plist-get p :key)
        `(("authorization" . ,(concat "Bearer " (ema-secret (plist-get p :key))))))))

(defun ema--openai-parse (json)
  "Turn chat-completions JSON into the neutral reply plist."
  (let* ((choice (aref (plist-get json :choices) 0))
         (msg (plist-get choice :message))
         (text (plist-get msg :content))
         (calls (plist-get msg :tool_calls))
         (u (plist-get json :usage))
         blocks)
    (when (and (stringp text) (not (string-empty-p text)))
      (push (list :type "text" :text text) blocks))
    (when (vectorp calls)
      (seq-doseq (c calls)
        (let* ((f (plist-get c :function))
               (args (plist-get f :arguments)))
          (push (list :type "tool_use" :id (plist-get c :id)
                      :name (plist-get f :name)
                      :input (condition-case nil
                                 (ema--json-parse
                                  (if (string-empty-p args) "{}" args))
                               (error (list :_invalid_json args))))
                blocks))))
    (list :content (vconcat (nreverse blocks))
          :stop (if (and (vectorp calls) (> (length calls) 0)) "tool_use"
                  (pcase (plist-get choice :finish_reason)
                    ("length" "max_tokens") (_ "end_turn")))
          :usage (list :in (or (plist-get u :prompt_tokens) 0)
                       :cached (or (plist-get
                                    (plist-get u :prompt_tokens_details)
                                    :cached_tokens)
                                   0)
                       :out (or (plist-get u :completion_tokens) 0)))))

;;;; Transport

(defvar ema-request-timeout 600
  "Seconds before a model request is abandoned.")

(defconst ema--wire-formats
  '((anthropic :headers ema--anthropic-headers
               :body ema--anthropic-body
               :parse ema--anthropic-parse)
    (openai    :headers ema--openai-headers
               :body ema--openai-body
               :parse ema--openai-parse))
  "The functions of each wire format, by the :api of a provider.")

(defun ema--wire (p part)
  "Return the function for PART of the wire format of provider plist P.
PART is :headers, :body or :parse.  An :api that is not `openai' is
treated as `anthropic'."
  (plist-get (alist-get (if (eq (plist-get p :api) 'openai) 'openai 'anthropic)
                        ema--wire-formats)
             part))

(defun ema--request-headers (p)
  "Return the request headers for provider plist P, each value as bytes.
url.el refuses a request whose parts mix multibyte and unibyte strings."
  (mapcar (lambda (h) (cons (car h) (encode-coding-string (cdr h) 'utf-8)))
          (funcall (ema--wire p :headers) p)))

(defun ema--response-json ()
  "Return the JSON body of the HTTP response in the current buffer, or nil."
  (when (bound-and-true-p url-http-end-of-headers)
    (ignore-errors
      (ema--json-parse
       (decode-coding-string
        (buffer-substring-no-properties url-http-end-of-headers (point-max))
        'utf-8)))))

(defun ema--error-text (json status)
  "Extract a readable error from JSON for HTTP STATUS."
  (let ((e (and (listp json) (plist-get json :error))))
    (format "HTTP %s: %s" status
            (cond ((stringp e) e)
                  ((and (listp e) (plist-get e :message)))
                  (t "no error detail")))))

(defun ema--response-reply (p status)
  "Return the neutral reply for the HTTP response in the current buffer.
P is the provider plist; STATUS is what `url-retrieve' passed to its
callback.  A failure comes back as (:error STRING)."
  (let ((http (bound-and-true-p url-http-response-status))
        (json (ema--response-json)))
    (cond ((and http (>= http 400))
           (list :error (ema--error-text json http)))
          ((plist-get status :error)
           (list :error (format "%S" (plist-get status :error))))
          ((null json)
           (list :error "the answer is not JSON"))
          (t (condition-case err
                 (funcall (ema--wire p :parse) json)
               (error (list :error (error-message-string err))))))))

(defun ema--response-retry-p (attempt)
  "Non-nil when the response in the current buffer deserves another try.
That is a 429 or a 5xx answer, while ATTEMPT (the retries so far) is
below 2."
  (let ((http (bound-and-true-p url-http-response-status)))
    (and http (or (= http 429) (>= http 500)) (< attempt 2))))

(defun ema-llm-cancel (request)
  "Stop REQUEST, the buffer that `ema-llm-request' returned."
  (when (buffer-live-p request)
    (let ((proc (get-buffer-process request))
          (kill-buffer-query-functions nil))
      (when proc (delete-process proc))
      (kill-buffer request))))

(defun ema-llm-request (system messages tools callback &optional attempt provider)
  "Send the conversation to a provider; return the request buffer.
PROVIDER is a provider plist; the default is the current provider.  A
call with an explicit PROVIDER is an independent adapter instance: it
does not touch `ema-provider', so a configuration can be tried first.
SYSTEM is a string, MESSAGES a list of neutral messages, TOOLS a list of
tool plists (:name :description :input_schema).  CALLBACK receives a
plist: (:content VECTOR :stop STRING :usage PLIST) or (:error STRING).
ATTEMPT counts retries of 429 and 5xx answers."
  (let* ((p (or provider (ema-provider-plist)))
         (attempt (or attempt 0))
         (url-request-method "POST")
         (url-request-extra-headers (ema--request-headers p))
         (url-request-data
          (ema--json-encode
           (funcall (ema--wire p :body) p system messages tools)))
         (done nil) (timer nil) (request nil)
         ;; the answer and the timeout race: only the first one settles
         (settle (lambda (&optional reply)
                   (unless done
                     (setq done t)
                     (when timer (cancel-timer timer))
                     (when reply (funcall callback reply))))))
    (setq request
          (url-retrieve
           (encode-coding-string (plist-get p :url) 'utf-8)
           (lambda (status)
             (let ((retry (ema--response-retry-p attempt))
                   (reply (ema--response-reply p status)))
               (kill-buffer (current-buffer))
               (cond (done nil)
                     (retry
                      (funcall settle)
                      (run-at-time (* 3 (1+ attempt)) nil #'ema-llm-request
                                   system messages tools callback (1+ attempt) p))
                     (t (funcall settle reply)))))
           nil t t))
    (setq timer
          (run-at-time ema-request-timeout nil
                       (lambda ()
                         (ema-llm-cancel request)
                         (funcall settle (list :error "request timed out")))))
    request))

(provide 'ema-llm)
;;; ema-llm.el ends here
