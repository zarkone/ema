;;; ema-tests.el --- Tests for ema -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'ema)
(require 'dired)
(require 'org)

(defmacro ema-tests--with-chat (&rest body)
  "Run BODY with a fresh chat buffer and a scratch state directory."
  `(let* ((ema-directory (file-name-as-directory (make-temp-file "ema-test" t)))
          (ema-tools (copy-sequence ema-tools)))
     (unwind-protect
         (progn (when (get-buffer "*ema*") (kill-buffer "*ema*"))
                ,@body)
       (when (get-buffer "*ema*") (kill-buffer "*ema*"))
       (delete-directory ema-directory t))))

(ert-deftest ema-cell-value-output-error ()
  (should (equal (ema-eval-cell "(+ 1 2)") "=> 3"))
  (should (equal (ema-eval-cell "(princ \"hi\") (list 1 2)") "output:\nhi\n=> (1 2)"))
  (should (string-prefix-p "error: " (ema-eval-cell "(car 1)")))
  (should (string-match-p "similar name" (ema-eval-cell "(ema-eval-cel 1)")))
  ;; an unbalanced cell is an error, not a silently shorter cell
  (should (string-prefix-p "error: " (ema-eval-cell "(setq ema-tests--x 1) (+ 1"))))

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
   (should (string-match-p "(ema-tests-twice n) — Return N times two." (ema-tools-index)))
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
                               (ema-action-save 'tighten "Make this shorter." "t" 'line)))
       (should-error (ema-action-save 'other "x" "r"))   ; r is review's key
       (should (eq (lookup-key ema-command-map "t") 'ema-act-tighten))
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

(ert-deftest ema-secret-from-file-and-env ()
  (let ((ema-secrets-file (make-temp-file "ema-secrets" nil nil
                                          "other=1\nllm.key.test = \"abc\"\n"))
        (process-environment (cons "LLM_KEY_ENVONLY=xyz" process-environment)))
    (unwind-protect
        (progn (should (equal (ema-secret "llm.key.test") "abc"))
               (should (equal (ema-secret "llm.key.envonly") "xyz"))
               (should-error (ema-secret "llm.key.missing")))
      (delete-file ema-secrets-file))))

(ert-deftest ema-buffer-text-reads-buffers-and-files ()
  (let ((file (make-temp-file "ema-text" nil ".txt" "a\nb\nc\n")))
    (unwind-protect
        (progn
          (should (equal (ema-buffer-text file 2 3) "2\tb\n3\tc"))
          (should-not (find-buffer-visiting file))
          (with-temp-buffer
            (insert "x\ny")
            (should (equal (ema-buffer-text (buffer-name)) "1\tx\n2\ty")))
          (should-error (ema-buffer-text "/no/such/file")))
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
    (should (string-match-p "ema-llm\\.el — [A-Z]" files)))
  (should (string-match-p "ema-actions\\.el" (ema-self-description)))
  (dolist (skill '("intro" "self" "organizer"))
    (should (string-match-p (concat "^" skill " — ") (ema-skills-index))))
  (let ((ema--self-check-time nil))
    (should-error (ema-self-reload))))

(provide 'ema-tests)
;;; ema-tests.el ends here
