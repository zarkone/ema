Organizer: plans and todos in org files, and the user's global org agenda

Use this when the user plans work, asks for a todo, asks what is open,
or when a task is large enough to need a plan that outlives the chat.

## Two levels

1. **The project file.** Each project has one `todo.org` at its root
   (`(ema-project)` gives the root). Plans and todos for that project go
   there. Use the file that exists; create it with the first entry.
2. **The global agenda.** `org-agenda-files` is the user's list of files
   that the agenda reads; it is how they track all projects in one
   place. `(ema-agenda-files)` shows the list.

When you write to a project's `todo.org` and that file is not on the
agenda, offer it once: `(ema-agenda-add FILE "why")`. It asks the user
and remembers the file for later sessions. After a "declined", do not
offer that file again; save that as a memory of the project with
`ema-memory-save`.

## Read before you write

- `(ema-todos FILE)`: the open entries of one file. `(ema-todos)`: the
  open entries of all agenda files.
- `org-todo-keywords` holds the user's states. Use their states, never
  invent one.
- The memories in your prompt hold what the user decided earlier, such
  as an agenda offer they declined.

## The form of an entry

A task that comes from a request:

    * TODO Short title, an action
    ** Request
    #+begin_quote
    The user's words, unchanged.
    #+end_quote
    ** Plan
    - [ ] First step
    - [ ] Second step

- `(ema-todo-add FILE "Title" "body")` adds an entry;
  `(ema-todo-add FILE "Title" "body" "Parent title")` adds a child.
- Link to code with `[[file:src/parse.el::120]]`, relative to the org
  file.
- A plan is steps the user can check, not prose. Three to seven steps.

## Tick as the work moves

- Start: `(ema-todo-state FILE "Title" "IN-PROGRESS")`, when the user
  has that state.
- A step is done: tick its checkbox with `ema-edit` (`- [ ]` to `- [X]`).
- All done and checked: `(ema-todo-state FILE "Title" "DONE")`. Mark
  DONE only what you verified or what the user confirmed.
- Never delete an entry; the user archives.

## Show, do not paste

- One project: `(ema-show FILE LINE)`.
- All projects: `(org-todo-list)` or `(org-agenda nil "t")` opens the
  user's own agenda view.
- In the chat, give a count and the two or three items that matter.

## Dates and the user's own files

- Set a date only when the user states one: `org-schedule` or
  `org-deadline` on the entry, with an explicit date string.
- `org-directory` (their notes) is theirs. Read it when they ask; write
  there only when they name the file.
- They may have no capture templates. Do not create templates or change
  org settings without a yes.
