;;; ema-history.el --- Conversations, calls and cells in SQLite -*- lexical-binding: t -*-

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

;; Everything a conversation does is recorded in one SQLite database,
;; history.sqlite in `ema-directory': the messages as they go to the
;; model, every model call with its tokens and duration, every cell with
;; its code and result.  Each conversation carries its project, so the
;; history is per project where that matters (resume, search) and whole
;; where that helps (analysis of runs).
;;
;; There is no archive step: old rows stay in the database, and what the
;; model sees is decided by the window in ema.el.  A failure of the
;; database never stops a turn.
;;
;; The file, top to bottom:
;;
;;   The database         the schema, open and close, `ema--with-history'
;;   Write, Read          what the chat records and loads (ema.el calls
;;                        these `ema--history-…' functions)
;;   Stored provider configurations   the rows behind `ema-current-config'
;;   Which tools the prompt lists in full
;;   History, Memory      the tools of the agent

;;; Code:

(require 'ema-llm)
(require 'ema-tools)

;;;; The database

(defcustom ema-history-enabled t
  "Non-nil records conversations in the history database."
  :type 'boolean :group 'ema)

(defconst ema--history-schema
  '("create table if not exists prompts (
       hash text primary key, text text not null)"
    "create table if not exists conversations (
       id integer primary key,
       project text,              -- project root, or null outside a project
       started real not null,     -- unix time
       updated real not null,
       title text,                -- first line of the first request
       provider text, model text, -- at the start
       ema_commit text,           -- git commit of ema's source
       prompt text,               -- prompts.hash of the system prompt
       window_start integer not null default 0)"
    "create table if not exists messages (
       id integer primary key,
       conversation integer not null,
       seq integer not null,      -- 0-based position in the conversation
       role text not null,        -- user | assistant
       content text not null,     -- JSON array of blocks, as sent
       request text,              -- the user's own words, for a request
       time real not null)"
    "create table if not exists calls (
       id integer primary key,
       conversation integer not null,
       provider text, model text,
       ms integer,
       tokens_in integer, tokens_cached integer, tokens_out integer,
       stop text, error text,
       time real not null)"
    "create table if not exists cells (
       id integer primary key,
       conversation integer not null,
       n integer not null,        -- cell number in the conversation
       code text not null,
       result text,               -- the digest the model saw
       status text,               -- done | error
       ms integer,
       time real not null)"
    "create table if not exists memories (
       id integer primary key,
       project text,              -- project root, or null for a global memory
       title text not null check (length(title) between 1 and 200),
       body text not null default '',
       created real not null,
       updated real not null)"
    "create table if not exists project_config (
       project text primary key,  -- project root (absolute path), or 'default'
       provider text not null,    -- key in ema-providers
       model text,                -- null = the provider's own default model
       options text,              -- JSON of overrides: effort, ...
       updated real not null)"
    "create index if not exists memories_project on memories (project, updated)"
    "create index if not exists messages_conv on messages (conversation, seq)"
    "create index if not exists calls_conv on calls (conversation)"
    "create index if not exists cells_conv on cells (conversation, n)"
    "create index if not exists conversations_project on conversations (project, updated)"
    "create virtual table if not exists history_fts using fts5 (
       text, kind unindexed, conversation unindexed, ref unindexed)")
  "The schema of the history database.")

(defvar ema-source-directory)

(defvar ema--history-db nil "The open database: (FILE . HANDLE).")
(defvar ema--history-warned nil
  "Non-nil after the one message that says the history is not recorded.")

(defun ema--history-file ()
  "Return the path of the history database."
  (ema--state-file "history.sqlite"))

(defun ema-history-close ()
  "Close the history database."
  (when ema--history-db
    (ignore-errors (sqlite-close (cdr ema--history-db)))
    (setq ema--history-db nil)))

(defun ema--history ()
  "Return the open history database, or nil when history is off."
  (when (and ema-history-enabled
             (fboundp 'sqlite-available-p) (sqlite-available-p))
    (let ((file (ema--history-file)))
      (unless (equal (car ema--history-db) file)
        (ema-history-close)
        (make-directory (file-name-directory file) t)
        (let ((db (sqlite-open file)))
          (dolist (sql ema--history-schema) (sqlite-execute db sql))
          (setq ema--history-db (cons file db))))
      (cdr ema--history-db))))

(defmacro ema--with-history (db &rest body)
  "Run BODY with DB bound to the database; never signal, return nil on failure."
  (declare (indent 1))
  `(condition-case err
       (when-let* ((,db (ema--history))) ,@body)
     (error
      (unless ema--history-warned
        (setq ema--history-warned t)
        (message "ema: history is not recorded: %s" (error-message-string err)))
      nil)))

(defun ema--history-or-error ()
  "Return the open history database, or signal an error when history is off.
The tools of the agent use it: an error tells the model why nothing came
back.  What the chat records goes through `ema--with-history'."
  (or (ema--history) (error "The history database is off")))

(defun ema--last-id (db)
  "Return the id of the row that the last insert into DB made."
  (caar (sqlite-select db "select last_insert_rowid()")))

(defun ema--project-clause (project &optional column)
  "Return (SQL . ARGUMENTS) that selects the rows of PROJECT.
PROJECT is a project root, or nil for the rows without a project.
COLUMN is the name of the project column (default \"project\")."
  (let ((column (or column "project")))
    (if project
        (cons (concat column " = ?") (list project))
      (cons (concat column " is null") nil))))

(defun ema--json-text (obj)
  "Serialize OBJ to JSON as a multibyte string."
  (decode-coding-string (ema--json-encode obj) 'utf-8))

;;;; Write

(defun ema--blocks-text (content)
  "Return the plain text of the blocks in CONTENT, for the search index."
  (mapconcat (lambda (block)
               (pcase (plist-get block :type)
                 ("text" (or (plist-get block :text) ""))
                 (_ "")))
             content "\n"))

(defun ema--source-commit ()
  "Return the short git commit of ema's own source, or nil."
  (ignore-errors
    (let ((default-directory ema-source-directory))
      (with-temp-buffer
        (and (eq 0 (process-file "git" nil t nil "rev-parse" "--short" "HEAD"))
             (string-trim (buffer-string)))))))

(defun ema--history-start (project title system)
  "Record a new conversation; return its id, or nil."
  (ema--with-history db
    (let ((hash (secure-hash 'sha1 system))
          (now (float-time))
          (p (ema-provider-plist)))
      (sqlite-execute db "insert or ignore into prompts values (?, ?)" (list hash system))
      (sqlite-execute
       db "insert into conversations
             (project, started, updated, title, provider, model, ema_commit, prompt)
           values (?, ?, ?, ?, ?, ?, ?, ?)"
       (list project now now title (symbol-name (ema-current-provider))
             (plist-get p :model) (ema--source-commit) hash))
      (ema--last-id db))))

(defun ema--history-message (conversation seq role content &optional request)
  "Record message SEQ of CONVERSATION."
  (ema--with-history db
    (let ((now (float-time)))
      (sqlite-execute
       db "insert into messages (conversation, seq, role, content, request, time)
           values (?, ?, ?, ?, ?, ?)"
       (list conversation seq role (ema--json-text content) request now))
      (let ((text (or request (ema--blocks-text content))))
        (unless (string-empty-p (string-trim text))
          (sqlite-execute
           db "insert into history_fts (text, kind, conversation, ref) values (?, ?, ?, ?)"
           (list text (if request "request" role) conversation seq))))
      (sqlite-execute db "update conversations set updated = ? where id = ?"
                      (list now conversation)))))

(defun ema--history-call (conversation ms usage stop error)
  "Record one model call of CONVERSATION."
  (ema--with-history db
    (let ((p (ema-provider-plist)))
      (sqlite-execute
       db "insert into calls (conversation, provider, model, ms, tokens_in,
             tokens_cached, tokens_out, stop, error, time)
           values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
       (list conversation (symbol-name (ema-current-provider)) (plist-get p :model) ms
             (plist-get usage :in) (plist-get usage :cached) (plist-get usage :out)
             stop error (float-time))))))

(defun ema--history-cell (conversation n code result status ms)
  "Record cell N of CONVERSATION."
  (ema--with-history db
    (sqlite-execute
     db "insert into cells (conversation, n, code, result, status, ms, time)
         values (?, ?, ?, ?, ?, ?, ?)"
     (list conversation n code result (symbol-name status) ms (float-time)))
    (sqlite-execute
     db "insert into history_fts (text, kind, conversation, ref) values (?, ?, ?, ?)"
     (list (concat code "\n" result) "cell" conversation n))))

(defun ema--history-set-window (conversation start)
  "Record that the window of CONVERSATION starts at message START."
  (ema--with-history db
    (sqlite-execute db "update conversations set window_start = ? where id = ?"
                    (list start conversation))))

;;;; Read

(defun ema--history-conversations (project &optional limit)
  "Return the conversations of PROJECT, newest first: (ID UPDATED TITLE MESSAGES)."
  (ema--with-history db
    (pcase-let ((`(,where . ,args) (ema--project-clause project "c.project")))
      (sqlite-select
       db (concat "select c.id, c.updated, coalesce(c.title, ''),
                     (select count(*) from messages m where m.conversation = c.id)
                   from conversations c where " where
                  " order by c.updated desc limit ?")
       (append args (list (or limit 200)))))))

(defun ema--history-load (conversation)
  "Return the stored state of CONVERSATION as a plist.
The keys are :messages, :requests ((SEQ . TEXT)…), :window-start and
:cells (the highest cell number)."
  (ema--with-history db
    (let ((rows (sqlite-select
                 db "select seq, role, content, request from messages
                     where conversation = ? order by seq"
                 (list conversation))))
      (list :messages (mapcar (lambda (r)
                                (list :role (nth 1 r)
                                      :content (ema--json-parse (nth 2 r))))
                              rows)
            :requests (delq nil (mapcar (lambda (r) (and (nth 3 r) (cons (nth 0 r) (nth 3 r))))
                                        rows))
            :window-start (or (caar (sqlite-select
                                     db "select window_start from conversations where id = ?"
                                     (list conversation)))
                              0)
            :cells (or (caar (sqlite-select
                              db "select max(n) from cells where conversation = ?"
                              (list conversation)))
                       0)))))

(defun ema-history-delete (conversation)
  "Delete CONVERSATION (an id) from the history database."
  (ema--with-history db
    (dolist (table '("messages" "calls" "cells" "history_fts"))
      (sqlite-execute db (format "delete from %s where conversation = ?" table)
                      (list conversation)))
    (sqlite-execute db "delete from conversations where id = ?" (list conversation))
    t))

;;;; Stored provider configurations (see `ema-current-config')

(defun ema--config-row (key)
  "Return the stored configuration of KEY, or nil.
KEY is a project root or `ema-default-config-key'.  The result is a plist
\(:provider SYMBOL :model STRING-OR-NIL :options PLIST)."
  (ema--with-history db
    (when-let* ((r (car (sqlite-select
                         db "select provider, model, options from project_config
                             where project = ?"
                         (list key)))))
      (list :provider (intern (nth 0 r))
            :model (and (stringp (nth 1 r)) (nth 1 r))
            :options (and (stringp (nth 2 r)) (ema--json-parse (nth 2 r)))))))

(defun ema-config-save (key provider model options)
  "Store PROVIDER, MODEL and OPTIONS for KEY; return non-nil when written.
KEY is a project root or `ema-default-config-key'.  MODEL may be nil (the
provider's own); OPTIONS is a plist of overrides such as :effort."
  (prog1 (ema--with-history db
           (sqlite-execute
            db "insert or replace into project_config
                  (project, provider, model, options, updated)
                values (?, ?, ?, ?, ?)"
            (list key (symbol-name provider) model
                  (and options (ema--json-text options)) (float-time)))
           t)
    (ema-config-flush)))

(setq ema-config-store-function #'ema--config-row)

;;;; Which tools the prompt lists in full

(defun ema--tool-uses (&optional limit)
  "Return an alist (TOOL . CELLS): how many recorded cells call each tool.
Only the latest LIMIT cells count (default 2000)."
  (ema--with-history db
    (let ((counts nil))
      (dolist (row (sqlite-select
                    db "select code from cells order by id desc limit ?"
                    (list (or limit 2000))))
        (let ((code (car row)) (start 0) (seen nil))
          (while (string-match
                  "\\(?:\\`\\|[^-a-z0-9]\\)\\(ema-[a-z0-9-]*[a-z0-9]\\)" code start)
            (setq start (match-end 1))
            (let ((sym (intern-soft (match-string 1 code))))
              (when (and sym (memq sym ema-tools) (not (memq sym seen)))
                (push sym seen)
                (cl-incf (alist-get sym counts 0)))))))
      counts)))

(defun ema-tools-daily ()
  "Return the tools that get a full line in the prompt.
These are `ema-doc', then the tools that the history shows as much used
\(`ema-tools-daily-min-uses'), then `ema-tools-daily-seed'; at most
`ema-tools-daily-count' in all."
  (let* ((used (seq-filter (lambda (c) (>= (cdr c) ema-tools-daily-min-uses))
                           (ema--tool-uses)))
         (ranked (mapcar #'car (sort used (lambda (a b) (> (cdr a) (cdr b)))))))
    (seq-take (seq-filter (lambda (sym) (memq sym ema-tools))
                          (seq-uniq (append '(ema-doc) ranked ema-tools-daily-seed)))
              ema-tools-daily-count)))

;;;; History: earlier conversations

(ema-deftool ema-conversation ()
  "Return (:id N :project ROOT) of the conversation you are in.
N is the id in the history database; nil when history is off."
  (if (buffer-live-p ema--current-chat)
      (with-current-buffer ema--current-chat
        (list :id (bound-and-true-p ema--conversation)
              :project (bound-and-true-p ema--project)))
    (list :id nil :project nil)))

(ema-deftool ema-history (words &optional all-projects limit)
  "Search earlier conversations for WORDS; return one line per hit.
The search is full-text over the user's requests, your replies and the
cells (code and result).  All WORDS must occur.  It covers the project
of this conversation; with ALL-PROJECTS non-nil, every project.  A line
is \"conversation ID · date · kind ref | snippet\": kind is request,
assistant or cell; ref is the message seq or the cell number.  Read
more with `ema-history-sql'.  LIMIT defaults to 20."
  (let* ((db (ema--history-or-error))
         (project (plist-get (ema-conversation) :project))
         (match (mapconcat (lambda (w) (format "\"%s\"" (string-replace "\"" "\"\"" w)))
                           (split-string words nil t) " "))
         (rows (sqlite-select
                db (concat
                    "select f.conversation, date(c.started, 'unixepoch', 'localtime'),
                       f.kind, f.ref, snippet(history_fts, 0, '[', ']', '…', 16)
                     from history_fts f join conversations c on c.id = f.conversation
                     where history_fts match ? "
                    (cond (all-projects "")
                          (project "and c.project = ? ")
                          (t "and c.project is null "))
                    "order by c.started desc, f.rowid desc limit ?")
                (append (list match)
                        (and (not all-projects) project (list project))
                        (list (or limit 20))))))
    (if rows
        (mapconcat (lambda (r)
                     (format "conversation %s · %s · %s %s | %s"
                             (nth 0 r) (nth 1 r) (nth 2 r) (nth 3 r)
                             (replace-regexp-in-string "[\n\t ]+" " " (nth 4 r))))
                   rows "\n")
      "no hits")))

(ema-deftool ema-history-sql (sql &optional limit)
  "Run one read-only SELECT on the history database; return the rows.
Use it to read old conversations and to analyze runs.  Tables:
  conversations (id, project, started, updated, title, provider, model,
                 ema_commit, prompt, window_start)
  messages (conversation, seq, role, content, request, time)
  calls    (conversation, provider, model, ms, tokens_in, tokens_cached,
            tokens_out, stop, error, time)
  cells    (conversation, n, code, result, status, ms, time)
  prompts  (hash, text)       -- system prompts; conversations.prompt
  memories (id, project, title, body, created, updated)
Times are unix seconds: datetime(time, \\='unixepoch\\=', \\='localtime\\=').
messages.content is the JSON array of blocks as sent to the model
\(json_each and json_extract work); messages.request is the user's own
words on a request message and null elsewhere.  cells.status is done or
error.  At most LIMIT rows come back (default 200).
Example: select n, status, ms, substr(code, 1, 80) from cells
         where conversation = 12 order by n"
  (let ((db (ema--history-or-error)))
    (unless (string-match-p "\\`[ \t\n]*\\(?:select\\|with\\)\\b" (downcase sql))
      (error "Only SELECT statements run here"))
    (sqlite-execute db "pragma query_only = 1")
    (unwind-protect
        (seq-take (sqlite-select db sql) (or limit 200))
      (sqlite-execute db "pragma query_only = 0"))))

;;;; Memory: short facts, global or for one project

(defcustom ema-memory-window '(15 . 25)
  "How many memory titles the prompt lists: (GLOBAL . PROJECT), newest first."
  :type '(cons integer integer) :group 'ema)

(defun ema--memory-rows (db project limit)
  "Return (ID TITLE) of the newest LIMIT memories of PROJECT (nil: global)."
  (pcase-let ((`(,where . ,args) (ema--project-clause project)))
    (sqlite-select
     db (concat "select id, title from memories where " where
                " order by updated desc limit ?")
     (append args (list limit)))))

(defun ema--memory-count (db project)
  "Return how many memories PROJECT has (nil: the global ones)."
  (pcase-let ((`(,where . ,args) (ema--project-clause project)))
    (caar (sqlite-select
           db (concat "select count(*) from memories where " where) args))))

(defun ema-memory-section (project)
  "Return the prompt section that lists the memories for PROJECT."
  (or
   (ema--with-history db
     (let* ((global (ema--memory-rows db nil (car ema-memory-window)))
            (local (and project (ema--memory-rows db project (cdr ema-memory-window))))
            (more-global (- (ema--memory-count db nil) (length global)))
            (more-local (if project (- (ema--memory-count db project) (length local)) 0)))
       (concat
        "\n## Memory\n\n"
        "Titles of the facts you saved in earlier conversations. "
        "Read a body with `(ema-memory ID)` when a title fits the task.\n"
        (if global (concat "\nGlobal:\n" (ema--memory-lines global) "\n") "")
        (if local (concat "\nThis project:\n" (ema--memory-lines local) "\n") "")
        (if (or global local) "" "\n(no memories yet)\n")
        (ema--memory-more-note more-local more-global))))
   ""))

(defun ema--memory-lines (rows)
  "Return ROWS ((ID TITLE)...) as a list for the prompt, one line each."
  (mapconcat (lambda (r) (format "- #%d %s" (nth 0 r) (nth 1 r))) rows "\n"))

(defun ema--memory-more-note (more-local more-global)
  "Return the prompt line on the memories that the prompt does not list.
MORE-LOCAL and MORE-GLOBAL count them; the line is empty when both are 0."
  (let ((parts (delq nil (list (and (> more-local 0)
                                    (format "%d more for this project" more-local))
                               (and (> more-global 0)
                                    (format "%d more global" more-global))))))
    (if parts
        (format "\n(%s: find them with `(ema-memory-search \"words\")`)\n"
                (string-join parts ", "))
      "")))

(defun ema--memory-project ()
  "Return the project that a new memory belongs to: the one of this conversation."
  (plist-get (ema-conversation) :project))

(ema-deftool ema-memory-save (title &optional body global id)
  "Save a memory: a short fact that will matter in later conversations.
TITLE is one line of at most 200 characters that states the fact itself;
it is what later conversations see in the prompt.  BODY holds details,
the reason, the date.  The memory belongs to this conversation's
project; with GLOBAL non-nil, or outside a project, it is global (a
preference of the user, a fact about this machine).  With ID, that
memory is replaced.  Returns \"memory #N saved (scope)\".
Save: decisions and preferences the user states, facts that took work
to find.  Do not save what the repository already says."
  (let ((db (ema--history-or-error))
        (project (and (not global) (ema--memory-project)))
        (now (float-time))
        (title (string-trim (or title ""))))
    (when (string-match-p "\n" title) (error "TITLE must be one line"))
    (unless (<= 1 (length title) 200)
      (error "TITLE has %d characters; the limit is 200. Put details in BODY"
             (length title)))
    (if id
        (progn
          (unless (sqlite-select db "select 1 from memories where id = ?" (list id))
            (error "No memory #%s" id))
          (sqlite-execute
           db "update memories set title = ?, body = ?, project = ?, updated = ? where id = ?"
           (list title (or body "") project now id)))
      (sqlite-execute
       db "insert into memories (project, title, body, created, updated) values (?, ?, ?, ?, ?)"
       (list project title (or body "") now now))
      (setq id (ema--last-id db)))
    (format "memory #%d saved (%s)" id
            (if project (concat "project " (abbreviate-file-name project)) "global"))))

(ema-deftool ema-memory (id)
  "Return memory ID whole: scope, date, title and body."
  (let* ((db (ema--history-or-error))
         (row (car (sqlite-select
                    db "select project, date(updated, 'unixepoch', 'localtime'), title, body
                        from memories where id = ?"
                    (list id)))))
    (unless row (error "No memory #%s" id))
    (format "#%d · %s · %s\n%s\n\n%s" id
            (if (nth 0 row) (abbreviate-file-name (nth 0 row)) "global")
            (nth 1 row) (nth 2 row) (nth 3 row))))

(ema-deftool ema-memory-search (&optional words limit)
  "Return the memories whose title or body has all WORDS, newest first.
The search covers the global memories and the ones of this project.
Without WORDS, all of them.  A line is \"#ID [scope] title\".  LIMIT
defaults to 50."
  (let* ((db (ema--history-or-error))
         (project (ema--memory-project))
         (terms (split-string (or words "") nil t))
         (rows (sqlite-select
                db (concat "select id, project is null, title from memories where "
                           (if project "(project is null or project = ?)" "project is null")
                           (mapconcat (lambda (_) " and (title || ' ' || body) like ? escape '\\'")
                                      terms "")
                           " order by updated desc limit ?")
                (append (and project (list project))
                        (mapcar (lambda (w)
                                  (concat "%" (replace-regexp-in-string
                                               "[%_\\]" "\\\\\\&" w)
                                          "%"))
                                terms)
                        (list (or limit 50))))))
    (if rows
        (mapconcat (lambda (r) (format "#%d [%s] %s" (nth 0 r)
                                       (if (eq 1 (nth 1 r)) "global" "project") (nth 2 r)))
                   rows "\n")
      "no memories match")))

(ema-deftool ema-memory-delete (id)
  "Delete memory ID: use it when the fact is wrong or no longer true."
  (let ((db (ema--history-or-error)))
    (unless (sqlite-select db "select 1 from memories where id = ?" (list id))
      (error "No memory #%s" id))
    (sqlite-execute db "delete from memories where id = ?" (list id))
    (format "memory #%s deleted" id)))

;; a reload reopens the database, so that a new schema applies
(ema-history-close)

(provide 'ema-history)
;;; ema-history.el ends here
