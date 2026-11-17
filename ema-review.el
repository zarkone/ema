;;; ema-review.el --- Review notes on lines, and changes the user accepts -*- lexical-binding: t -*-

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

;; Two ways in which ema comments on the user's code without taking it
;; over:
;;
;;   Notes        `ema-note' puts a remark under a line, as an overlay.
;;                The file does not change.  Where flymake is on, a note
;;                is also a diagnostic.
;;   Suggestions  `ema-suggest' shows a change as a diff and waits until
;;                the user accepts or declines it.
;;
;; All tools of this file are in one tool group, the `;;;;' heading
;; below; the parts of the file have `;;;' headings for that reason.

;;; Code:

(require 'ema-tools)
(require 'diff)

(declare-function flymake-make-diagnostic "flymake")
(declare-function flymake-start "flymake")
(defvar flymake-diagnostic-functions)

(defface ema-noted-line '((t :inherit highlight))
  "Face of a line that carries an ema review note."
  :group 'ema)
(defface ema-note-text '((t :inherit warning :slant italic))
  "Face of an ema review note."
  :group 'ema)

;;;; Review: notes on lines, changes the user accepts

;;; Notes

(defun ema--note-overlays ()
  "Return the note overlays of the current buffer, in buffer order."
  (save-restriction
    (widen)
    (sort (seq-filter (lambda (ov) (overlay-get ov 'ema-note))
                      (overlays-in (point-min) (point-max)))
          (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(defun ema-flymake (report-fn &rest _)
  "A flymake backend: report the ema review notes as diagnostics."
  (funcall report-fn
           (mapcar (lambda (ov)
                     (flymake-make-diagnostic
                      (current-buffer) (overlay-start ov) (overlay-end ov)
                      :note (concat "ema: " (overlay-get ov 'ema-note))))
                   (ema--note-overlays))))

(defun ema--notes-changed ()
  "Tell flymake, when it is on here, that the notes changed."
  (when (bound-and-true-p flymake-mode)
    (add-hook 'flymake-diagnostic-functions #'ema-flymake nil t)
    (ignore-errors (flymake-start))))

(ema-deftool ema-note (buffer line text)
  "Attach review note TEXT to LINE of BUFFER, shown under that line.
The note is an overlay: it does not change the file.  Use it to review
code in place: one short note per finding, then a summary in the chat.
Where flymake is on, the note is also a diagnostic, so the user's usual
keys and lists reach it.  The user moves between notes with
\\[ema-next-note] and \\[ema-previous-note] and removes them with \\[ema-clear-notes]."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (ema--goto-line line)
        (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
          (overlay-put ov 'ema-note text)
          (overlay-put ov 'face 'ema-noted-line)
          (overlay-put ov 'after-string
                       (propertize (concat "\n  ▸ " (string-replace "\n" "\n    " text))
                                   'face 'ema-note-text))
          (overlay-put ov 'evaporate t))))
    (ema--notes-changed)
    (ema--push-mark)
    (ema--side-window (current-buffer))
    (format "note on %s:%d" (buffer-name) line)))

(ema-deftool ema-notes (&optional buffer)
  "Return the review notes in BUFFER (default: current) as \"line: text\"."
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (mapcar (lambda (ov)
                (format "%d: %s" (line-number-at-pos (overlay-start ov))
                        (overlay-get ov 'ema-note)))
              (ema--note-overlays)))))

;;; Notes: the commands of the user

(defun ema-clear-notes (&optional buffer)
  "Remove the ema review notes from BUFFER (default: the current buffer)."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'face 'ema-noted-line))
    (ema--notes-changed)))

(defun ema-next-note (&optional backward)
  "Move to the next ema review note; with BACKWARD, to the previous one."
  (interactive "P")
  (let* ((starts (mapcar #'overlay-start (ema--note-overlays)))
         (to (if backward
                 (car (last (seq-filter (lambda (p) (< p (line-beginning-position))) starts)))
               (seq-find (lambda (p) (> p (line-end-position))) starts))))
    (unless starts (user-error "No ema notes in this buffer"))
    (goto-char (or to (if backward (car (last starts)) (car starts))))
    (message "%s" (overlay-get (seq-find (lambda (ov) (overlay-get ov 'ema-note))
                                         (overlays-at (point)))
                               'ema-note))))

(defun ema-previous-note ()
  "Move to the previous ema review note."
  (interactive)
  (ema-next-note t))

;;; Suggestions

;; A suggestion does not ask in the minibuffer.  A minibuffer question
;; holds the keyboard: the user who goes to read the code first works
;; with a prompt open behind them, and the next prompt stacks on it.
;; `ema-suggest' waits in a recursive edit instead: the user moves
;; freely and answers with a key in the diff buffer, or with M-x from
;; any buffer.

(defvar ema--suggestion-waiting nil
  "Non-nil while `ema-suggest' waits for the answer of the user.")

(defun ema--suggestion-answer (answer)
  (unless ema--suggestion-waiting
    (user-error "ema does not wait for an answer"))
  (throw 'ema-suggestion answer))

(defun ema-suggestion-apply ()
  "Accept the change that ema suggests."
  (interactive)
  (ema--suggestion-answer 'apply))

(defun ema-suggestion-decline ()
  "Decline the change that ema suggests."
  (interactive)
  (ema--suggestion-answer 'decline))

(defvar ema-suggestion-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "y" #'ema-suggestion-apply)
    (define-key map "n" #'ema-suggestion-decline)
    (define-key map (kbd "C-c C-c") #'ema-suggestion-apply)
    (define-key map (kbd "C-c C-k") #'ema-suggestion-decline)
    map)
  "Keys of the diff buffer while ema waits for an answer.")

(define-minor-mode ema-suggestion-mode
  "Answer keys in the buffer that shows a suggestion of ema.
\\{ema-suggestion-mode-map}"
  :lighter " ema?"
  (if ema-suggestion-mode
      ;; ahead of the keys that `diff-mode' gives a read-only buffer
      (setq-local minor-mode-overriding-map-alist
                  (cons (cons 'ema-suggestion-mode ema-suggestion-mode-map)
                        minor-mode-overriding-map-alist))
    (setq-local minor-mode-overriding-map-alist
                (assq-delete-all 'ema-suggestion-mode
                                 minor-mode-overriding-map-alist))))

(defun ema--suggestion-wait (diff question)
  "Wait for the answer to QUESTION about the change in buffer DIFF.
Return non-nil when the user accepts.  The wait is a recursive edit, not
a minibuffer prompt: the user can read other buffers first.  They answer
with y or n in DIFF, or with `ema-suggestion-apply' and
`ema-suggestion-decline' from any buffer.  To kill DIFF is to decline."
  (let ((ema--suggestion-waiting t)
        (declined (lambda () (when ema--suggestion-waiting
                               (throw 'ema-suggestion 'decline))))
        (keys "y apply, n decline")
        (origin (selected-window)))
    (unwind-protect
        (progn
          (with-current-buffer diff
            (ema-suggestion-mode 1)
            (setq header-line-format
                  (concat " " (propertize question 'face 'bold) "  " keys))
            (add-hook 'kill-buffer-hook declined nil t))
          (when-let* ((win (get-buffer-window diff)))
            (select-window win))
          (message "%s  %s (in the diff buffer)" question keys)
          (eq 'apply (catch 'ema-suggestion (recursive-edit) 'decline)))
      (when (buffer-live-p diff)
        (with-current-buffer diff
          (remove-hook 'kill-buffer-hook declined t)
          (ema-suggestion-mode -1)
          (setq header-line-format nil)))
      (when (window-live-p origin) (select-window origin)))))

(defun ema--suggestion-diff (buf after file diff)
  "Fill buffer DIFF with the diff from BUF to AFTER, named as FILE.
The header names FILE, so that the `diff-mode' commands that go to the
source find it and do not ask for a file."
  (diff-no-select buf after "-u" t diff)
  (with-current-buffer diff
    (setq default-directory (file-name-directory (expand-file-name file)))
    (let ((inhibit-read-only t)
          (name (file-name-nondirectory file)))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^--- .*$" nil t)
          (replace-match (concat "--- " name) t t))
        (when (re-search-forward "^\\+\\+\\+ .*$" nil t)
          (replace-match (concat "+++ " name) t t))))))

(ema-deftool ema-suggest (file old new &optional why)
  "Propose to replace OLD with NEW in FILE; the user accepts or declines.
The change is shown as a diff beside the chat with the reason WHY.  The
call waits until the user answers with a key in the diff buffer; they
can read other buffers first.  Returns \"applied\" or \"declined\".
This is the default way to change the user's code: they stay the
author.  OLD must occur exactly once (see `ema-edit')."
  (let* ((buf (find-file-noselect file))
         (after (generate-new-buffer " *ema-after*"))
         (diff (get-buffer-create "*ema: suggestion*")))
    (unwind-protect
        (progn
          (with-current-buffer after
            (insert (with-current-buffer buf
                      (save-restriction (widen) (buffer-string))))
            (ema--replace-once old new file))
          (ema--suggestion-diff buf after file diff)
          (ema--side-window diff)
          (if (ema--suggestion-wait
               diff (format "ema suggests%s. Apply?"
                            (if why (concat ": " (string-trim-right why "[. ]+"))
                              " a change")))
              (progn (ema-edit file old new) "applied (not saved)")
            "declined"))
      (kill-buffer after))))

(provide 'ema-review)
;;; ema-review.el ends here
