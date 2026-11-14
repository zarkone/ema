;;; ema-tests.el --- Tests for ema -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'ema)
(require 'dired)
(require 'org)

(defun ema-tests--kill-chats ()
  (dolist (b (ema--chats)) (kill-buffer b))
  (ema-history-close))

(defmacro ema-tests--with-chat (&rest body)
  "Run BODY with a fresh chat buffer and a scratch state directory.
The directory is not a project, so the chat is \"*ema*\"."
  `(let* ((ema-directory (file-name-as-directory (make-temp-file "ema-test" t)))
          (default-directory ema-directory)
          (ema-tools (copy-sequence ema-tools)))
     (unwind-protect
         (progn (ema-tests--kill-chats)
                ,@body)
       (ema-tests--kill-chats)
       (delete-directory ema-directory t))))

(ert-deftest ema-transcript-is-read-only ()
  (ema-tests--with-chat
   (with-current-buffer (ema--chat-buffer)
     (ema--insert "\nreply\n")
     ;; refused every time, not only the first (a before-change hook would reset itself)
     (dotimes (_ 3)
       (should-error (progn (goto-char 3) (insert "X")) :type 'text-read-only)
       (should-error (progn (goto-char ema--input) (delete-char -1)) :type 'text-read-only))
     (goto-char ema--input)
     (insert "typed")
     (should (equal (buffer-substring-no-properties ema--input (point-max)) "typed"))
     (ema--insert "\nmore\n")
     (should-error (progn (goto-char 3) (insert "X")) :type 'text-read-only)
     (should (equal (buffer-substring-no-properties ema--input (point-max)) "typed")))))

(ert-deftest ema-cell-value-output-error ()
  (should (equal (ema-eval-cell "(+ 1 2)") "=> 3"))
  (should (equal (ema-eval-cell "(princ \"hi\") (list 1 2)") "output:\nhi\n=> (1 2)"))
  (should (string-prefix-p "error: " (ema-eval-cell "(car 1)")))
  (should (string-match-p "similar name" (ema-eval-cell "(ema-eval-cel 1)")))
  ;; an unbalanced cell is an error, not a silently shorter cell
  (should (string-prefix-p "error: " (ema-eval-cell "(setq ema-tests--x 1) (+ 1"))))

(ert-deftest ema-tools-index-is-short-and-grouped ()
  (let ((index (ema-tools-index '(ema-search ema-doc))))
    ;; a daily tool has its signature; the others are names under a group
    (should (string-match-p "^(ema-doc symbol) — " index))
    (should (string-match-p "^(ema-search regexp &optional files dir show) — " index))
    (should-not (string-match-p "(ema-memory-save " index))
    (should (string-match-p "^Memory — ema-memory-save, ema-memory, " index))
    ;; a group comes from the `;;;;' heading above the tool, or from the
    ;; first line of a file without headings
    (should (string-match-p "^Git — ema-git$" index))
    (should (string-match-p "^Packages — ema-packages, ema-package-search, ema-install$"
                            index))
    (should (string-match-p "^Plans, todos and the org agenda — ema-agenda-files, " index))
    ;; every tool is in the index exactly once
    (dolist (sym (seq-difference ema-tools '(ema-doc ema-tool-group)))
      (should (= 1 (with-temp-buffer
                     (insert index)
                     (emacs-lisp-mode)
                     (how-many (format "\\_<%s\\_>" (regexp-quote (symbol-name sym)))
                               (point-min) (point-max))))))
    (should (< (length index) (/ (length (ema-tool-group)) 2))))
  (should (string-match-p "^(ema-memory id) — " (ema-tool-group "memory")))
  (should-error (ema-tool-group "no such group")))

(ert-deftest ema-tools-daily-follows-the-history ()
  (ema-tests--with-chat
   (let ((ema-tools-daily-count 3) (ema-tools-daily-min-uses 2))
     ;; an empty history: `ema-doc', then the seed
     (should (equal (ema-tools-daily)
                    (seq-take (seq-uniq (cons 'ema-doc ema-tools-daily-seed)) 3)))
     (dotimes (n 2)
       (ema--history-cell 1 n "(ema-todos) (ema-todos \"x\")" "=> x" 'done 1))
     (ema--history-cell 1 3 "(ema-notes) (not-ema-todos)" "=> x" 'done 1)
     (should (equal (seq-take (ema-tools-daily) 2) '(ema-doc ema-todos)))
     (should-not (memq 'ema-notes (ema-tools-daily))))))

(ert-deftest ema-cell-error-teaches-the-failed-tool ()
  (skip-unless (fboundp 'handler-bind-1))
  ;; a wrong call: the whole documentation
  (let ((digest (ema-eval-cell "(ema-doc)")))
    (should (string-prefix-p "error: " digest))
    (should (string-match-p "The documentation of ema-doc:" digest))
    (should (string-match-p "(ema-doc symbol)" digest)))
  ;; another error inside a tool: one line
  (let ((digest (ema-eval-cell "(ema-skill \"no such skill\")")))
    (should (string-match-p "The failed tool: (ema-skill name) — " digest)))
  ;; an error outside a tool, and an error that the cell handles: nothing
  (should-not (string-match-p "tool" (ema-eval-cell "(car 1)")))
  (should (equal (ema-eval-cell "(condition-case nil (ema-doc) (error 7))") "=> 7")))

(ert-deftest ema-cell-state-persists ()
  (ema-eval-cell "(setq ema-tests--kept 41)")
  (should (equal (ema-eval-cell "(1+ ema-tests--kept)") "=> 42")))

(ert-deftest ema-cell-large-value-is-stubbed ()
  (let* ((ema-digest-limit 50)
         (digest (ema-eval-cell "(make-string 500 ?x)")))
    (should (string-match "(ema-value \\([0-9]+\\))" digest))
    (should (= 500 (length (ema-value (string-to-number (match-string 1 digest))))))
    (should (= 500 (length (substring (ema-eval-cell "(make-string 500 ?x)" t) 3))))))

(ert-deftest ema-tool-save-and-reload ()
  (ema-tests--with-chat
   (ema-tool-save "(ema-deftool ema-tests-twice (n)\n  \"Return N times two.\"\n  (* 2 n))")
   (should (= 8 (ema-tests-twice 4)))
   (should (string-match-p "(ema-tests-twice n) — Return N times two."
                           (ema-tools-index '(ema-tests-twice))))
   ;; a tool without a source heading is in the group of added tools
   (should (string-match-p "^Added tools — ema-tests-twice$" (ema-tools-index)))
   (should (string-match-p "(ema-tests-twice n) — Return N times two."
                           (ema-tool-group "added")))
   (fmakunbound 'ema-tests-twice)
   (ema-load-tools)
   (should (= 8 (ema-tests-twice 4)))
   (should-error (ema-tool-save "(defun x ())"))
   (ema-skill-save "tea" "How the user takes tea\n\nBlack.")
   (should (string-match-p "tea — How the user takes tea" (ema-skills-index)))
   (should (string-match-p "Black" (ema-skill "tea")))))

(ert-deftest ema-edit-replaces-once ()
  (let ((file (make-temp-file "ema-edit" nil ".txt" "one\ntwo\ntwo\n")))
    (unwind-protect
        (progn
          (should-error (ema-edit file "two" "2"))
          (ema-edit file "one\ntwo" "1\ntwo" t)
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                         "1\ntwo\ntwo\n")))
      (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
      (delete-file file))))

(ert-deftest ema-notes-and-state ()
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (let ((name (buffer-name)))
      (cl-letf (((symbol-function 'ema--side-window) #'ignore))
        (ema-note name 2 "off by one"))
      (should (equal (ema-notes name) '("2: off by one")))
      (should (equal (buffer-string) "a\nb\nc\n"))
      (ema-clear-notes)
      (should-not (ema-notes name))
      (should (plist-member (ema-state name) :mode-line)))))

(ert-deftest ema-suggest-applies-only-on-yes ()
  (let ((file (make-temp-file "ema-sug" nil ".txt" "alpha\nbeta\n")))
    (unwind-protect
        (cl-letf (((symbol-function 'ema--side-window)
                   (lambda (b) (display-buffer b))))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
            (should (equal (ema-suggest file "beta" "gamma" "test") "declined")))
          (should (equal (with-current-buffer (get-file-buffer file) (buffer-string))
                         "alpha\nbeta\n"))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
            (should (string-prefix-p "applied" (ema-suggest file "beta" "gamma"))))
          (should (equal (with-current-buffer (get-file-buffer file) (buffer-string))
                         "alpha\ngamma\n"))
          (should (string-match-p "^\\+gamma"
                                  (with-current-buffer "*ema: suggestion*" (buffer-string)))))
      (with-current-buffer (get-file-buffer file) (set-buffer-modified-p nil))
      (kill-buffer (get-file-buffer file))
      (delete-file file))))

(ert-deftest ema-install-asks-first ()
  (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
            ((symbol-function 'package-install)
             (lambda (&rest _) (error "must not install"))))
    (should (equal (ema-install 'ema-no-such-package "test") "declined"))))

(ert-deftest ema-provider-switch-tests-first ()
  (ema-tests--with-chat
   (let ((ema-providers (copy-tree ema-providers))
         (ema-provider 'anthropic)
         (ema-secret-function (lambda (_) "k"))
         seen)
     (cl-letf (((symbol-function 'ema-llm-request)
                (lambda (_s _m _t callback _a provider)
                  (push (plist-get provider :model) seen)
                  (funcall callback
                           (if (equal (plist-get provider :model) "good")
                               (list :content [(:type "tool_use" :id "x" :name "eval"
                                                      :input (:code "(+ 1 1)"))]
                                     :stop "tool_use")
                             (list :error "HTTP 404: no such model")))
                  nil)))
       ;; a failed test changes nothing
       (should (string-prefix-p "NOT switched" (ema-provider-switch 'openai "bad")))
       (should (eq ema-provider 'anthropic))
       (should-not (equal (plist-get (ema-provider-plist 'openai) :model) "bad"))
       ;; a test alone never switches
       (should (plist-get (ema-provider-test 'openai "good") :ok))
       (should (eq ema-provider 'anthropic))
       ;; a passed test switches and saves
       (should (string-prefix-p "switched" (ema-provider-switch 'openai "good" :effort "low")))
       (should (eq ema-provider 'openai))
       (should (equal seen '("good" "good" "bad")))
       ;; the user's pick from a proposal goes through the same path
       (cl-letf (((symbol-function 'ema--annotated-read)
                  (lambda (_prompt rows) (car (nth 1 rows)))))
         (should (string-prefix-p
                  "NOT switched"
                  (ema-provider-propose '((anthropic "good" "a") (anthropic "bad" "b"))))))
       (should (eq ema-provider 'openai))
       ;; the saved configuration comes back
       (setq ema-provider 'anthropic)
       (setf (alist-get 'openai ema-providers) nil)
       (ema-load-config)
       (should (eq ema-provider 'openai))
       (should (equal (plist-get (ema-provider-plist 'openai) :effort) "low"))
       (should (string-match-p "^\\* openai  model good" (ema-providers-list)))))))

(ert-deftest ema-context-region-defun-line ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun a ()\n  1)\n\n(defun b ()\n  (+ 1\n     2))\n")
    (goto-char (point-min))
    (search-forward "(+ 1")
    (let ((line (ema-context)) (def (ema-context 'defun)))
      (should (string-match-p ":5\\'" (plist-get line :label)))
      (should (string-match-p "line 5, column" (plist-get line :text)))
      (should (string-match-p "| in b" (plist-get line :text)))
      (should (string-match-p ":4-6\\'" (plist-get def :label)))
      (should (string-match-p "^4\t(defun b ()" (plist-get def :text)))
      (should-not (string-match-p "defun a" (plist-get def :text))))
    ;; an active region wins over the scope
    (let ((transient-mark-mode t))
      (goto-char (point-min))
      (set-mark (point))
      (forward-line 2)
      (activate-mark)
      (let ((reg (ema-context 'defun)))
        (should (string-match-p ":1-2\\'" (plist-get reg :label)))
        (should (string-match-p "context: region" (plist-get reg :text)))))))

(ert-deftest ema-action-sends-context-with-pre-prompt ()
  (ema-tests--with-chat
   (let ((ema-actions (copy-tree ema-actions))
         (ema--stored-actions nil)
         (ema-command-map (copy-keymap ema-command-map))
         sent)
     (cl-letf (((symbol-function 'ema-llm-request)
                (lambda (_s messages &rest _) (setq sent messages) nil))
               ((symbol-function 'ema--show-chat) #'ignore))
       (should (string-match-p "ema-act-tighten"
                               (ema-action-save 'tighten "Make this shorter." "y" 'line)))
       (should-error (ema-action-save 'other "x" "r"))   ; r is review's key
       (should (eq (lookup-key ema-command-map "y") 'ema-act-tighten))
       (with-temp-buffer
         (insert "first\nsecond\n")
         (goto-char (point-min))
         (forward-line 1)
         (call-interactively 'ema-act-tighten))
       (let ((text (plist-get (aref (plist-get (car sent) :content) 0) :text)))
         (should (string-match-p "\\[context: line" text))
         (should (string-match-p "^2\tsecond" text))
         (should (string-suffix-p "Make this shorter." text)))
       (with-current-buffer "*ema*"
         (should (string-match-p "› tighten  ⟨" (buffer-string)))
         (setq ema--busy nil))
       ;; saved actions come back
       (setq ema-actions (assq-delete-all 'tighten ema-actions))
       (ema-load-actions)
       (should (alist-get 'tighten ema-actions))
       (ema-action-delete 'tighten)
       (should-not (alist-get 'tighten ema-actions))
       (fmakunbound 'ema-act-tighten)))))

(ert-deftest ema-openai-conversion ()
  (let* ((messages
          (list (list :role "user" :content [(:type "text" :text "hi")])
                (list :role "assistant"
                      :content [(:type "thinking" :thinking "" :signature "s")
                                (:type "text" :text "ok")
                                (:type "tool_use" :id "t1" :name "eval"
                                       :input (:code "(+ 1 1)"))])
                (list :role "user"
                      :content [(:type "tool_result" :tool_use_id "t1" :content "=> 2")])))
         (out (ema--openai-messages "sys" messages)))
    (should (equal (mapcar (lambda (m) (plist-get m :role)) out)
                   '("system" "user" "assistant" "tool")))
    (should (equal (plist-get (aref out 3) :tool_call_id) "t1"))
    (should (ema--json-encode (list :messages out))))
  (let ((reply (ema--openai-parse
                (ema--json-parse
                 "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"eval\",\"arguments\":\"{\\\"code\\\":\\\"(+ 1 1)\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":7}}"))))
    (should (equal (plist-get reply :stop) "tool_use"))
    (should (equal (plist-get (plist-get (aref (plist-get reply :content) 0) :input) :code)
                   "(+ 1 1)"))))

(ert-deftest ema-loop-runs-cells-until-text ()
  "The loop with a scripted model: one cell, then a text reply."
  (ema-tests--with-chat
   (let ((script (list (list :content [(:type "tool_use" :id "t1" :name "eval"
                                               :input (:code "(* 6 7)"))]
                             :stop "tool_use" :usage '(:in 10 :cached 0 :out 5))
                       (list :content [(:type "text" :text "It is 42.")]
                             :stop "end_turn" :usage '(:in 12 :cached 10 :out 4))))
         seen)
     (cl-letf (((symbol-function 'ema-llm-request)
                (lambda (_system messages _tools callback &rest _)
                  (push (copy-sequence messages) seen)
                  (funcall callback (pop script))
                  nil)))
       (ema-submit "what is six times seven?")
       (with-current-buffer "*ema*"
         (should-not ema--busy)
         (should (= 4 (length ema--messages)))
         (should (equal (plist-get (aref (plist-get (nth 2 ema--messages) :content) 0)
                                   :content)
                        "=> 42"))
         (should (equal ema--usage '(:in 22 :cached 10 :out 9)))
         (should (string-match-p "It is 42\\." (buffer-string)))
         ;; the turn leaves one line that links to the log, not the cell
         (should (string-match-p "▸ cell #1" (buffer-string)))
         (should-not (string-match-p "(\\* 6 7)" (buffer-string)))
         (should (string-suffix-p "› " (buffer-string)))
         (should-not ema--cells)
         (should (string-match-p "── #1 · .*\n(\\* 6 7)\n=> 42"
                                 (with-current-buffer ema-log-buffer-name
                                   (buffer-string))))
         (should (string-match-p "\\[view\\]"
                                 (plist-get (aref (plist-get (car ema--messages) :content) 0)
                                            :text))))))))

(ert-deftest ema-token-speed-of-the-last-call ()
  "The header and the activity show the out tokens per second of the last call."
  (ema-tests--with-chat
   (let ((chat (ema--chat-buffer)))
     (with-current-buffer chat
       ;; a small, slow call: 100 out tokens over 10 seconds
       (let ((ema--call-start (- (float-time) 10.0)))
         (ema--on-reply (list :content [(:type "text" :text "hi")]
                              :stop "end_turn" :usage '(:in 10 :cached 0 :out 100))))
       (should (= 10 ema--speed))
       (should (string-match-p "out 100 (10/s)" (ema--header)))
       (let ((ema--busy t))
         (should (string-match-p "· 10 tok/s" (ema--activity))))
       ;; a call too fast to trust the clock: the last speed stays
       (let ((ema--call-start (- (float-time) 0.1)))
         (ema--on-reply (list :content [(:type "text" :text "hi")]
                              :stop "end_turn" :usage '(:in 10 :cached 0 :out 100))))
       (should (= 10 ema--speed))))))

(ert-deftest ema-secrets-in-auth-source ()
  (let* ((file (make-temp-file "ema-authinfo"))
         (auth-sources (list file))
         (ema-secret-store-file file)
         (auth-source-save-behavior t)
         (ema-providers '((p1 :key "llm.key.test") (p2 :key "llm.key.other")
                          (local :key nil)))
         (process-environment (cons "LLM_KEY_ENVONLY=xyz" process-environment)))
    (unwind-protect
        (progn
          (auth-source-forget-all-cached)
          (should-error (ema-secret "llm.key.test"))
          (should (equal (ema-secret "llm.key.envonly") "xyz"))
          (should (equal (ema-secret-names) '("llm.key.test" "llm.key.other")))
          ;; the agent's tool: the user types, the value does not come back
          (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (copy-sequence "abc-123"))))
            (let ((result (ema-secret-ask "llm.key.test")))
              (should (string-match-p "\\`saved in " result))
              (should-not (string-match-p "abc-123" result)))
            (should-error (ema-secret-ask "llm.key.unknown")))
          (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (signal 'quit nil))))
            (should (equal (ema-secret-ask "llm.key.other") "cancelled")))
          (should (equal (ema-secret "llm.key.test") "abc-123"))
          (should (string-match-p "machine llm\\.key\\.test login ema password abc-123"
                                  (with-temp-buffer (insert-file-contents file)
                                                    (buffer-string))))
          (let ((status (ema-secrets-status)))
            (should (string-match-p "llm\\.key\\.test: present" status))
            (should (string-match-p "llm\\.key\\.other: missing" status))
            (should-not (string-match-p "abc-123" status)))
          ;; no encrypted file configured: refuse, do not write plain text
          (let ((ema-secret-store-file nil) (auth-sources '("~/.authinfo")))
            (should-error (ema-secret-store "llm.key.other" "v")))
          (let ((ema-secret-store-file nil)
                (auth-sources '((:source "~/x/.authinfo.gpg"))))
            (should (equal (ema--secret-store-file) "~/x/.authinfo.gpg"))))
      (auth-source-forget-all-cached)
      (delete-file file))))

(ert-deftest ema-buffer-text-reads-buffers-and-files ()
  (let ((file (make-temp-file "ema-text" nil ".txt" "a\nb\nc\n")))
    (unwind-protect
        (progn
          (should (equal (ema-buffer-text file 2 3) "b\nc"))
          (should-not (find-buffer-visiting file))
          (with-temp-buffer
            (insert "x\ny")
            (should (equal (ema-buffer-text (buffer-name)) "x\ny")))
          (should-error (ema-buffer-text "/no/such/file"))
          ;; secret files are refused, as a file and as an open buffer
          (should-error (ema-buffer-text "~/.authinfo.gpg"))
          (let ((auth-sources (list file)))
            (should-error (ema-buffer-text file))
            (with-current-buffer (find-file-noselect file)
              (unwind-protect
                  (progn (should-error (ema-buffer-text (buffer-name)))
                         (should-error (ema-context)))
                (kill-buffer)))))
      (delete-file file))))

(ert-deftest ema-search-finds-lines ()
  (let ((dir (file-name-as-directory (make-temp-file "ema-search" t))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.el" dir) (insert ";; one\n(defun needle-a ())\n"))
          (with-temp-file (expand-file-name "b.txt" dir) (insert "needle-b\nother\n"))
          (let ((hits (ema-search "needle-[ab]" nil dir)))
            (should (string-match-p "a\\.el:2: (defun needle-a ())" hits))
            (should (string-match-p "b\\.txt:1: needle-b" hits)))
          (should-not (string-match-p "b\\.txt" (ema-search "needle" "\\.el\\'" dir)))
          (should (string-match-p "\\`no hits" (ema-search "absent-thing" nil dir)))
          (let ((ema-search-max-hits 1))
            (should (string-match-p "1 more hits" (ema-search "needle" nil dir)))))
      (delete-directory dir t))))

(ert-deftest ema-shell-returns-and-stops ()
  (should (equal (ema-shell "echo hi; exit 3") '(:exit 3 :output "hi\n")))
  (should-error (ema-shell "sleep 5" nil 0.3)))

(ert-deftest ema-run-is-asynchronous ()
  (unwind-protect
      (progn
        (should (string-match-p "started" (ema-run "sleep 0.3; echo done-marker; exit 2" nil "t")))
        (should (equal (plist-get (ema-run-result "t") :status) "running"))
        (should-error (ema-run "true" nil "t"))
        (let ((r (ema-run-result "t" 10)))
          (should (string-match-p "code 2" (plist-get r :status)))
          (should (string-match-p "done-marker" (plist-get r :output)))))
    (when (get-buffer "*ema-run: t*") (kill-buffer "*ema-run: t*"))))

(ert-deftest ema-git-without-magit ()
  (let ((default-directory (file-name-as-directory (make-temp-file "ema-git" t))))
    (unwind-protect
        (progn
          (should (= 0 (plist-get (ema-git "init" "-q") :exit)))
          (with-temp-file "f" (insert "x\n"))
          (ema-git "add" "f")
          (let ((r (ema-git "status" "--short")))
            (should (equal (plist-get r :output) "A  f\n"))
            (should (eq (plist-get r :via) 'git)))
          (should-error (ema-git 'status)))
      (delete-directory default-directory t))))

(ert-deftest ema-reply-paths-become-links ()
  (let ((dir (file-name-as-directory (make-temp-file "ema-link" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory dir)
          (make-directory (expand-file-name "src" dir))
          (with-temp-file (expand-file-name "src/a.el" dir) (insert "x\n"))
          (insert "See src/a.el:12 and src/none.el, also e.g. this.")
          (ema--linkify (point-min) (point-max))
          (let ((b (button-at 6)))
            (should b)
            (should (equal (button-get b 'ema-file) (expand-file-name "src/a.el" dir)))
            (should (= (button-get b 'ema-line) 12))
            (should (= (button-end b) 16)))
          (should-not (button-at 24))
          (should-not (button-at 40)))
      (delete-directory dir t))))

(ert-deftest ema-context-by-mode ()
  (let ((dir (file-name-as-directory (make-temp-file "ema-ctx" t))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "f.txt" dir) (insert "x\n"))
          (with-current-buffer (dired-noselect dir)
            (goto-char (point-min))
            (search-forward "f.txt")
            (let ((ctx (ema-context)))
              (should (equal (plist-get ctx :label) "f.txt"))
              (should (string-match-p "\\`\\[context: files" (plist-get ctx :text))))
            (kill-buffer))
          (with-temp-buffer
            (insert "* One\nbody\n** Two\ndeep\n* Three\n")
            (org-mode)
            (goto-char (point-min))
            (forward-line 1)
            (let ((text (plist-get (ema-context 'defun) :text)))
              (should (string-match-p "org subtree" text))
              (should (string-match-p "deep" text))
              (should-not (string-match-p "Three" text)))
            (should (string-match-p "\\[context: line" (plist-get (ema-context) :text)))))
      (delete-directory dir t))))

(ert-deftest ema-turn-edits-are-one-undo-step ()
  (let ((file (make-temp-file "ema-undo" nil ".txt" "one two three\n")))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (buffer-enable-undo)
          (ema-edit file "one" "1")
          (undo-boundary)
          (ema-edit file "two" "2")
          (ema--close-change-groups)
          (should (equal (buffer-string) "1 2 three\n"))
          (undo-boundary)
          (primitive-undo 1 (cdr (memq nil buffer-undo-list)))
          (should (equal (buffer-string) "one two three\n"))
          (set-buffer-modified-p nil)
          (kill-buffer))
      (delete-file file))))

(ert-deftest ema-notes-navigate ()
  (with-temp-buffer
    (insert "a\nb\nc\nd\n")
    (cl-letf (((symbol-function 'ema--side-window) #'ignore)
              ((symbol-function 'ema--push-mark) #'ignore))
      (ema-note (current-buffer) 2 "first")
      (ema-note (current-buffer) 4 "second"))
    (goto-char (point-min))
    (ema-next-note)
    (should (= (line-number-at-pos) 2))
    (ema-next-note)
    (should (= (line-number-at-pos) 4))
    (ema-previous-note)
    (should (= (line-number-at-pos) 2))
    (should (equal (ema-notes) '("2: first" "4: second")))))

(ert-deftest ema-organizer-todos-and-agenda ()
  (ema-tests--with-chat
   (let* ((dir (file-name-as-directory (make-temp-file "ema-org" t)))
          (file (expand-file-name "todo.org" dir))
          (org-agenda-files nil)
          (ema--agenda-added nil)
          (org-todo-keywords '((sequence "TODO" "IN-PROGRESS" "|" "DONE"))))
     (unwind-protect
         (progn
           (should (string-match-p "todo\\.org:1\\'"
                                   (ema-todo-add file "Ship it" "** Plan\n- [ ] one")))
           (ema-todo-add file "Write tests" nil "Ship it")
           (ema-todo-add file "Other")
           (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                          "* TODO Ship it\n** Plan\n- [ ] one\n** TODO Write tests\n* TODO Other\n"))
           (ema-todo-state file "Write tests" "DONE")
           (should-error (ema-todo-state file "Other" "NOPE"))
           (let ((open (ema-todos file)))
             (should (string-match-p "TODO Ship it" open))
             (should (string-match-p ":5: TODO Other" open))
             (should-not (string-match-p "Write tests" open)))
           (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
             (should (equal (ema-agenda-add file) "declined"))
             (should-not org-agenda-files))
           (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
             (should (equal (ema-agenda-add file "the plan") "added"))
             (should (equal (ema-agenda-add file) "already on the agenda")))
           (should (equal org-agenda-files (list file)))
           (should (string-match-p "\\[ema\\]" (ema-agenda-files)))
           (should (string-match-p "Ship it" (ema-todos)))
           (setq ema--agenda-added nil org-agenda-files nil)
           (ema-load-agenda)
           (should (equal org-agenda-files (list file))))
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file) (set-buffer-modified-p nil))
         (kill-buffer (get-file-buffer file)))
       (delete-directory dir t)))))

(ert-deftest ema-self-knows-its-files-and-gates-reload ()
  (let ((files (ema-self-files)))
    (dolist (name '("ema.el" "ema-actions.el" "ema-org.el" "core.md" "self.md"))
      (should (string-match-p (regexp-quote name) files)))
    (should (string-match-p "ema-llm\\.el — [A-Z]" files))
    ;; the folder says which files exist, not a list
    (should (string-match-p "ema-tests\\.el — [A-Z]" files)))
  ;; the prompt points at the list; it does not hold it
  (should (string-match-p "ema-self-files" (ema-self-description)))
  (should-not (string-match-p "ema-actions\\.el" (ema-self-description)))
  (dolist (skill '("intro" "self" "organizer" "providers" "packages"
                   "shortcuts" "extend"))
    (should (string-match-p (concat "^" skill " — ") (ema-skills-index))))
  (let ((ema--self-check-time nil))
    (should-error (ema-self-reload))))

(defun ema-tests--reply (&rest blocks)
  (list :content (vconcat blocks) :stop "end_turn" :usage '(:in 10 :cached 5 :out 3)))

(ert-deftest ema-history-records-and-resumes ()
  (ema-tests--with-chat
   (let ((script (list (list :content (vector '(:type "text" :text "I look.")
                                              '(:type "tool_use" :id "t1" :name "eval"
                                                :input (:code "(* 6 7)")))
                             :stop "tool_use" :usage '(:in 100 :cached 0 :out 9))
                       (ema-tests--reply '(:type "text" :text "It is 42 zebra.")))))
     (cl-letf (((symbol-function 'ema-llm-request)
                (lambda (_s _m _t callback &rest _) (funcall callback (pop script)) nil)))
       (ema-submit "what is six times seven?"))
     (let ((id (with-current-buffer "*ema*" ema--conversation)))
       (should (integerp id))
       (should (equal (ema-history-sql "select count(*) from messages") '((4))))
       (should (equal (ema-history-sql "select n, status, result from cells")
                      '((1 "done" "=> 42"))))
       (should (equal (ema-history-sql "select tokens_in, stop from calls order by id")
                      '((100 "tool_use") (10 "end_turn"))))
       (should (equal (ema-history-sql "select title, project from conversations")
                      '(("what is six times seven?" nil))))
       (should (string-match-p "assistant 3 | It is 42 \\[zebra\\]" (ema-history "zebra")))
       (should (string-match-p "cell 1" (ema-history "6 7")))
       (should (equal (ema-history "giraffe") "no hits"))
       (should-error (ema-history-sql "delete from cells"))
       ;; the database is read-only during the call: a hidden write does nothing
       (ema-history-sql "with x as (select 1) delete from cells")
       (should (equal (ema-history-sql "select count(*) from cells") '((1))))
       ;; a new conversation, then back
       (with-current-buffer "*ema*"
         (ema-new)
         (should-not ema--messages)
         (should-not ema--conversation))
       (ema-resume id)
       (with-current-buffer "*ema*"
         (should (= 4 (length ema--messages)))
         (should (= 1 ema--cell-count))
         (should (equal (plist-get (aref (plist-get (nth 2 ema--messages) :content) 0)
                                   :content)
                        "=> 42"))
         (should (string-match-p "› what is six times seven\\?" (buffer-string)))
         (should (string-match-p "It is 42 zebra" (buffer-string))))
       ;; the resumed conversation goes on in the same row
       (let ((script (list (ema-tests--reply '(:type "text" :text "Yes.")))) sent)
         (cl-letf (((symbol-function 'ema-llm-request)
                    (lambda (_s m _t callback &rest _)
                      (setq sent m) (funcall callback (pop script)) nil)))
           (ema-submit "sure?"))
         (should (= 5 (length sent)))
         (should (equal (ema-history-sql "select count(*) from conversations") '((1))))
         (should (equal (ema-history-sql "select count(*) from messages") '((6)))))
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
         (ema-forget id))
       (should (equal (ema-history-sql "select count(*) from messages") '((0))))))))

(ert-deftest ema-window-trims-in-steps ()
  (ema-tests--with-chat
   (let ((ema-context-high 1000) (ema-context-low 500) sent
         (usage 100))
     (cl-letf (((symbol-function 'ema-llm-request)
                (lambda (_s m _t callback &rest _)
                  (push m sent)
                  (funcall callback
                           (list :content (vector (list :type "text"
                                                        :text (make-string 400 ?x)))
                                 :stop "end_turn" :usage (list :in usage :cached 0 :out 1)))
                  nil)))
       (ema-submit "first request")
       (ema-submit "second request")
       (setq usage 2000)
       (ema-submit "third request")       ; sent whole; its usage passes the mark
       (should (= 5 (length (car sent))))
       (setq usage 300)
       (ema-submit "fourth request")
       (with-current-buffer "*ema*"
         (should (= 8 (length ema--messages)))
         (should (> ema--window-start 0))
         (should (ema--request-message-p (nth ema--window-start ema--messages))))
       (let* ((window (car sent))
              (first (aref (plist-get (car window) :content) 0)))
         (should (< (length window) 7))
         (should (string-match-p "not shown" (plist-get first :text)))
         (should (string-match-p "- first request" (plist-get first :text))))
       ;; stable until the next trim: the same start, the same note
       (let ((start (with-current-buffer "*ema*" ema--window-start))
             (note (plist-get (aref (plist-get (car (car sent)) :content) 0) :text)))
         (ema-submit "fifth request")
         (should (= start (with-current-buffer "*ema*" ema--window-start)))
         (should (equal note (plist-get (aref (plist-get (car (car sent)) :content) 0)
                                        :text))))
       (should (equal (ema-history-sql "select window_start > 0 from conversations")
                      '((1))))))))

(ert-deftest ema-one-chat-per-project-one-turn-at-a-time ()
  (ema-tests--with-chat
   (let* ((root (file-name-as-directory (make-temp-file "ema-proj" t)))
          (project-find-functions (list (lambda (dir)
                                          (and (string-prefix-p root (expand-file-name dir))
                                               (cons 'transient root))))))
     (unwind-protect
         (let ((chat (let ((default-directory root)) (ema--chat-buffer)))
               (plain (ema--chat-buffer)))
           (should (equal (buffer-name plain) "*ema*"))
           (should (string-match-p "\\`\\*ema: ema-proj" (buffer-name chat)))
           (should (eq chat (let ((default-directory root)) (ema--chat-buffer))))
           (should (equal (buffer-local-value 'ema--project chat) root))
           (should (eq chat (with-current-buffer chat (ema--chat-buffer))))
           (cl-letf (((symbol-function 'ema-llm-request) (lambda (&rest _) nil)))
             (let ((default-directory root)) (ema-submit "in the project"))
             (should (buffer-local-value 'ema--busy chat))
             (should-error (ema-submit "elsewhere") :type 'user-error)
             (with-current-buffer chat (ema-abort)))
           (should (equal (ema-history-sql "select project from conversations")
                          (list (list root)))))
       (delete-directory root t)))))

(ert-deftest ema-memory-window-in-the-prompt ()
  (ema-tests--with-chat
   (let* ((root "/tmp/ema-memory-project/")
          (chat (generate-new-buffer " *ema-memory-chat*"))
          (ema-memory-window '(1 . 2)))
     (unwind-protect
         (progn
           (with-current-buffer chat (setq-local ema--project root))
           (let ((ema--current-chat chat))
             (should (string-match-p "(no memories yet)" (ema-memory-section root)))
             (should (equal (ema-memory-save "Tests run with make test" "since 2026")
                            "memory #1 saved (project /tmp/ema-memory-project/)"))
             (ema-memory-save "The parser lives in parse.el")
             (ema-memory-save "Third fact about zebras" "striped")
             (should (equal (ema-memory-save "The user wants short replies" "" t)
                            "memory #4 saved (global)"))
             (ema-memory-save "The user's shell is fish" "" t)
             (should-error (ema-memory-save (make-string 201 ?x)))
             (should-error (ema-memory-save "two\nlines"))
             (should-error (ema-memory-save ""))
             ;; the SQL limit holds without the tool too
             (should-error (sqlite-execute
                            (ema--history)
                            "insert into memories (title, created, updated) values (?, 0, 0)"
                            (list (make-string 201 ?x))))
             (let ((section (ema-memory-section root)))
               (should (string-match-p "Global:\n- #5 The user's shell is fish\n" section))
               (should (string-match-p "This project:\n- #3 Third fact about zebras\n- #2 The parser"
                                       section))
               (should-not (string-match-p "#1 " section))
               (should (string-match-p "(1 more for this project, 1 more global: " section)))
             (should (string-match-p "Global:" (ema-memory-section nil)))
             (should-not (string-match-p "This project:" (ema-memory-section nil)))
             (should (equal (ema-memory-search "zebras striped")
                            "#3 [project] Third fact about zebras"))
             (should (string-match-p "#4 \\[global\\]" (ema-memory-search "user")))
             (should (equal (ema-memory-search "100%") "no memories match"))
             (should (string-match-p "since 2026" (ema-memory 1)))
             (ema-memory-save "Tests run with make check" "changed" nil 1)
             (should (string-match-p "make check" (ema-memory 1)))
             (ema-memory-delete 3)
             (should-error (ema-memory 3)))
           ;; another project sees only the global ones
           (with-current-buffer chat (setq-local ema--project "/tmp/other/"))
           (let ((ema--current-chat chat))
             (should-not (string-match-p "parser" (ema-memory-search)))))
       (kill-buffer chat)))))

(provide 'ema-tests)
;;; ema-tests.el ends here
