;;; ema-org.el --- Plans, todos and the org agenda -*- lexical-binding: t -*-

;;; Commentary:

;; The tools behind the `organizer' skill.  A project keeps its plans in
;; a todo.org; the user's `org-agenda-files' is the global view.  ema
;; adds a file to the agenda only after a yes, and keeps its own list of
;; the files it added (agenda.eld), so the user's init files stay as
;; they are.  Org loads on first use, not with ema.

;;; Code:

(require 'ema-tools)

(declare-function org-agenda-files "org")
(declare-function org-map-entries "org")
(declare-function org-get-todo-state "org")
(declare-function org-get-heading "org")
(declare-function org-entry-get "org")
(declare-function org-find-exact-headline-in-buffer "org")
(declare-function org-current-level "org")
(declare-function org-end-of-subtree "org")
(declare-function org-todo "org")
(defvar org-agenda-files)
(defvar org-done-keywords)
(defvar org-todo-keywords-1)

(defun ema--agenda-file ()
  (expand-file-name "agenda.eld" ema-directory))

(defvar ema--agenda-added nil
  "The files that ema added to the org agenda; saved in agenda.eld.")

(defun ema--agenda-apply ()
  "Put the files that ema added earlier on `org-agenda-files'."
  (when (listp org-agenda-files)
    (dolist (file ema--agenda-added)
      (when (file-exists-p file)
        (add-to-list 'org-agenda-files file t)))))

(defun ema-load-agenda ()
  "Load the list of agenda files that ema added; apply it when org loads."
  (let ((file (ema--agenda-file)))
    (when (file-readable-p file)
      (setq ema--agenda-added
            (ignore-errors (with-temp-buffer (insert-file-contents file)
                                             (read (current-buffer)))))))
  (with-eval-after-load 'org (ema--agenda-apply)))

(defun ema--on-agenda-p (file)
  (member (file-truename file) (mapcar #'file-truename (org-agenda-files))))

(ema-deftool ema-agenda-files ()
  "Return the files of the user's global org agenda, one per line.
A file that ema added is marked [ema]."
  (require 'org)
  (let ((files (org-agenda-files)))
    (if files
        (mapconcat (lambda (f)
                     (concat (abbreviate-file-name f)
                             (if (member (expand-file-name f) ema--agenda-added) " [ema]" "")))
                   files "\n")
      "the agenda has no files")))

(ema-deftool ema-agenda-add (file &optional why)
  "Ask the user, then add org FILE to their global agenda (`org-agenda-files').
WHY is one line that is part of the question.  Returns \"added\",
\"already on the agenda\" or \"declined\".  The file is remembered for
later sessions in ema's state directory; the user's init files do not
change."
  (require 'org)
  (let ((file (expand-file-name file)))
    (cond
     ((not (file-exists-p file)) (error "No file %s" file))
     ((ema--on-agenda-p file) "already on the agenda")
     ((not (listp org-agenda-files))
      (error "org-agenda-files is not a list here (%S); the user adds the file themselves"
             org-agenda-files))
     ((not (y-or-n-p (format "ema wants to add %s to your org agenda%s. Add? "
                             (abbreviate-file-name file)
                             (if why (concat " (" (string-trim-right why "[. ]+") ")") ""))))
      "declined")
     (t
      (cl-pushnew file ema--agenda-added :test #'equal)
      (make-directory ema-directory t)
      (with-temp-file (ema--agenda-file)
        (pp ema--agenda-added (current-buffer)))
      (ema--agenda-apply)
      "added"))))

(ema-deftool ema-todos (&optional file)
  "Return the open todo entries of org FILE, or of all agenda files.
One line per entry: \"file:line: STATE title\", with the scheduled date
and the deadline when the entry has them."
  (require 'org)
  (let* ((files (if file (list (expand-file-name file)) (org-agenda-files)))
         (lines
          (and files
               (delq nil
                     (org-map-entries
                      (lambda ()
                        (let ((state (org-get-todo-state)))
                          (when (and state (not (member state org-done-keywords)))
                            (format "%s:%d: %s %s%s%s"
                                    (abbreviate-file-name (buffer-file-name))
                                    (line-number-at-pos) state
                                    (substring-no-properties (org-get-heading t t t t))
                                    (if-let* ((s (org-entry-get nil "SCHEDULED")))
                                        (format "  scheduled %s" s) "")
                                    (if-let* ((d (org-entry-get nil "DEADLINE")))
                                        (format "  deadline %s" d) "")))))
                      nil files)))))
    (cond ((null files) "the agenda has no files; pass FILE")
          (lines (string-join lines "\n"))
          (t "no open entries"))))

(defun ema--org-heading (title)
  "Move to the heading TITLE in the current org buffer, or signal an error."
  (let ((marker (org-find-exact-headline-in-buffer title)))
    (unless marker (error "No heading \"%s\" in %s" title (buffer-name)))
    (goto-char marker)))

(ema-deftool ema-todo-add (file title &optional body parent)
  "Add the entry \"TODO TITLE\" to org FILE and save it; return \"file:line\".
BODY is org text under the heading (a quote, a checkbox plan); write
its sub-headings two levels deep (\"** Plan\"): they are moved under the
entry.  With PARENT (the exact title of a heading) the entry becomes
its last child; without it, a top-level entry at the end.  The file is
created when it does not exist."
  (require 'org)
  (with-current-buffer (find-file-noselect file)
    (unless (derived-mode-p 'org-mode) (error "%s is not an org file" file))
    (save-excursion
      (save-restriction
        (widen)
        (let ((level 1))
          (if parent
              (progn (ema--org-heading parent)
                     (setq level (1+ (org-current-level)))
                     (org-end-of-subtree t t))
            (goto-char (point-max)))
          (unless (bolp) (insert "\n"))
          (let ((line (line-number-at-pos))
                (shift (make-string (1- level) ?*)))
            (insert (make-string level ?*) " TODO " title "\n")
            (when (and body (not (string-empty-p (string-trim body))))
              (insert (replace-regexp-in-string
                       "^\\*\\*" (concat shift "**") (string-trim body))
                      "\n"))
            (save-buffer)
            (format "%s:%d" (abbreviate-file-name (buffer-file-name)) line)))))))

(ema-deftool ema-todo-state (file title state)
  "Set the entry with the exact TITLE in org FILE to STATE; save the file.
STATE is one of the user's keywords (see `org-todo-keywords'), such as
\"IN-PROGRESS\" or \"DONE\".  Returns \"file:line: STATE title\"."
  (require 'org)
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (save-restriction
        (widen)
        (ema--org-heading title)
        (unless (member state org-todo-keywords-1)
          (error "No state %s here; the states are %s" state org-todo-keywords-1))
        (org-todo state)
        (save-buffer)
        (format "%s:%d: %s %s" (abbreviate-file-name (buffer-file-name))
                (line-number-at-pos) state title)))))

(ema-load-agenda)

(provide 'ema-org)
;;; ema-org.el ends here
