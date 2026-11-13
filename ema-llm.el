;;; ema-llm.el --- Providers and secrets for ema -*- lexical-binding: t -*-

;;; Commentary:

;; One entry point: `ema-llm-request'.  The conversation is kept in one
;; neutral shape (the Anthropic Messages shape, as plists with vectors);
;; each provider API converts it on the way out and back.  That is what
;; makes a provider switch possible in the middle of a conversation.
;;
;; Secrets go through `ema-secret' only; the default source is auth-source.

;;; Code:

(require 'url)
(require 'url-http)
(require 'json)
(require 'subr-x)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

;;;; Secrets

(require 'auth-source)

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

(defun ema--secret-store-file ()
  "Return the file that receives a new secret, or signal an error."
  (or ema-secret-store-file
      (seq-find (lambda (f) (and (stringp f) (string-suffix-p ".gpg" f)))
                (mapcar (lambda (s) (if (stringp s) s (plist-get s :source)))
                        auth-sources))
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

(defvar ema-providers)

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
  (let ((value (read-passwd (format "Value of %s (not shown): " name))))
    (when (string-empty-p value) (user-error "Empty value; nothing saved"))
    (unwind-protect
        (message "ema: %s saved in %s" name
                 (abbreviate-file-name (ema-secret-store name value)))
      (clear-string value))))

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
  "The provider in use, a key of `ema-providers'.")

(defvar ema-request-timeout 600
  "Seconds before a model request is abandoned.")

(defun ema-provider-plist (&optional name)
  "Return the plist of provider NAME (default: the current one)."
  (or (alist-get (or name ema-provider) ema-providers)
      (error "ema: unknown provider %s" (or name ema-provider))))

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

(defun ema--error-text (json status)
  "Extract a readable error from JSON for HTTP STATUS."
  (let ((e (and (listp json) (plist-get json :error))))
    (format "HTTP %s: %s" status
            (cond ((stringp e) e)
                  ((and (listp e) (plist-get e :message)))
                  (t "no error detail")))))

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
         (openai (eq (plist-get p :api) 'openai))
         (url-request-method "POST")
         ;; url.el refuses a request whose parts mix multibyte and
         ;; unibyte strings: every header value goes out as bytes
         (url-request-extra-headers
          (mapcar (lambda (h) (cons (car h) (encode-coding-string (cdr h) 'utf-8)))
                  (if openai (ema--openai-headers p) (ema--anthropic-headers p))))
         (url-request-data
          (ema--json-encode
           (if openai (ema--openai-body p system messages tools)
             (ema--anthropic-body p system messages tools))))
         (attempt (or attempt 0))
         (done nil) (timer nil) (buf nil)
         (finish (lambda (reply)
                   (unless done
                     (setq done t)
                     (when timer (cancel-timer timer))
                     (funcall callback reply)))))
    (setq buf
          (url-retrieve
           (encode-coding-string (plist-get p :url) 'utf-8)
           (lambda (status)
             (let* ((http (bound-and-true-p url-http-response-status))
                    (raw (and (bound-and-true-p url-http-end-of-headers)
                              (buffer-substring-no-properties
                               url-http-end-of-headers (point-max))))
                    (json (and raw (condition-case nil
                                       (ema--json-parse
                                        (decode-coding-string raw 'utf-8))
                                     (error nil)))))
               (kill-buffer (current-buffer))
               (cond
                (done nil)
                ((and http (or (= http 429) (>= http 500)) (< attempt 2))
                 (setq done t)
                 (when timer (cancel-timer timer))
                 (run-at-time (* 3 (1+ attempt)) nil #'ema-llm-request
                              system messages tools callback (1+ attempt) p))
                ((and http (>= http 400))
                 (funcall finish (list :error (ema--error-text json http))))
                ((plist-get status :error)
                 (funcall finish
                          (list :error (format "%S" (plist-get status :error)))))
                ((null json)
                 (funcall finish (list :error "the answer is not JSON")))
                (t (funcall finish
                            (condition-case err
                                (if openai (ema--openai-parse json)
                                  (ema--anthropic-parse json))
                              (error (list :error (error-message-string err)))))))))
           nil t t))
    (setq timer
          (run-at-time ema-request-timeout nil
                       (lambda ()
                         (when (buffer-live-p buf)
                           (let ((proc (get-buffer-process buf))
                                 (kill-buffer-query-functions nil))
                             (when proc (delete-process proc))
                             (kill-buffer buf)))
                         (funcall finish (list :error "request timed out")))))
    buf))

(provide 'ema-llm)
;;; ema-llm.el ends here
