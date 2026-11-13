;;; ema-history.el --- Conversations, calls and cells in SQLite -*- lexical-binding: t -*-

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

;;; Code:

(require 'ema-llm)
(require 'ema-tools)

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
(defvar ema--history-warned nil)

(defun ema--history-file ()
  (expand-file-name "history.sqlite" ema-directory))

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

(defun ema--json-text (obj)
  "Serialize OBJ to JSON as a multibyte string."
  (decode-coding-string (ema--json-encode obj) 'utf-8))

(defun ema--blocks-text (content)
  "Return the plain text of the blocks in CONTENT, for the search index."
  (mapconcat (lambda (block)
               (pcase (plist-get block :type)
                 ("text" (or (plist-get block :text) ""))
                 (_ "")))
             content "\n"))

;;;; Write

(defun ema--source-commit ()
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
       (list project now now title (symbol-name ema-provider)
             (plist-get p :model) (ema--source-commit) hash))
      (caar (sqlite-select db "select last_insert_rowid()")))))

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
       (list conversation (symbol-name ema-provider) (plist-get p :model) ms
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
  (ema--with-history db
    (sqlite-execute db "update conversations set window_start = ? where id = ?"
                    (list start conversation))))

;;;; Read

(defun ema--history-conversations (project &optional limit)
  "Return the conversations of PROJECT, newest first: (ID UPDATED TITLE MESSAGES)."
  (ema--with-history db
    (sqlite-select
     db (concat "select c.id, c.updated, coalesce(c.title, ''),
                   (select count(*) from messages m where m.conversation = c.id)
                 from conversations c where "
                (if project "c.project = ?" "c.project is null")
                " order by c.updated desc limit ?")
     (append (and project (list project)) (list (or limit 200))))))

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

;;;; Tools for the agent

(defvar ema--current-chat)

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
  (let* ((db (or (ema--history) (error "The history database is off")))
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
  (let ((db (or (ema--history) (error "The history database is off"))))
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
  (sqlite-select
   db (concat "select id, title from memories where "
              (if project "project = ?" "project is null")
              " order by updated desc limit ?")
   (append (and project (list project)) (list limit))))

(defun ema--memory-count (db project)
  (caar (sqlite-select
         db (concat "select count(*) from memories where "
                    (if project "project = ?" "project is null"))
         (and project (list project)))))

(defun ema-memory-section (project)
  "Return the prompt section that lists the memories for PROJECT."
  (or
   (ema--with-history db
     (let* ((global (ema--memory-rows db nil (car ema-memory-window)))
            (local (and project (ema--memory-rows db project (cdr ema-memory-window))))
            (more-global (- (ema--memory-count db nil) (length global)))
            (more-local (if project (- (ema--memory-count db project) (length local)) 0))
            (lines (lambda (rows)
                     (mapconcat (lambda (r) (format "- #%d %s" (nth 0 r) (nth 1 r)))
                                rows "\n"))))
       (concat
        "\n## Memory\n\n"
        "These are titles of facts you saved in earlier conversations: global ones and the ones of this project. "
        "Read a body with `(ema-memory ID)` when a title fits the task, and save what will matter again with `ema-memory-save`.\n"
        (if global (concat "\nGlobal:\n" (funcall lines global) "\n") "")
        (if local (concat "\nThis project:\n" (funcall lines local) "\n") "")
        (if (or global local) "" "\n(no memories yet)\n")
        (if (or (> more-global 0) (> more-local 0))
            (format "\n(%s: find them with `(ema-memory-search \"words\")`)\n"
                    (string-join
                     (delq nil (list (and (> more-local 0)
                                          (format "%d more for this project" more-local))
                                     (and (> more-global 0)
                                          (format "%d more global" more-global))))
                     ", "))
          ""))))
   ""))

(defun ema--memory-project ()
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
  (let ((db (or (ema--history) (error "The history database is off")))
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
      (setq id (caar (sqlite-select db "select last_insert_rowid()"))))
    (format "memory #%d saved (%s)" id
            (if project (concat "project " (abbreviate-file-name project)) "global"))))

(ema-deftool ema-memory (id)
  "Return memory ID whole: scope, date, title and body."
  (let* ((db (or (ema--history) (error "The history database is off")))
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
  (let* ((db (or (ema--history) (error "The history database is off")))
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
  (let ((db (or (ema--history) (error "The history database is off"))))
    (unless (sqlite-select db "select 1 from memories where id = ?" (list id))
      (error "No memory #%s" id))
    (sqlite-execute db "delete from memories where id = ?" (list id))
    (format "memory #%s deleted" id)))

;; a reload reopens the database, so that a new schema applies
(ema-history-close)

(provide 'ema-history)
;;; ema-history.el ends here
