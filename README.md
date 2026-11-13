# ema

A minimal agent that lives in Emacs. It helps you work on your code;
it does not work in your place.

ema is synchronous on purpose. It does not run in the background and it
does not act on its own between your messages. You focus on one thing,
you ask, ema does one turn in front of you, and you go on. One turn runs
at a time, in the whole Emacs.

- **One tool.** The model has a single tool, `eval`: an Emacs Lisp cell
  that runs in your live Emacs.
- **Emacs is the persistent kernel.** What a cell defines stays defined.
  A long result is cut and stored; `(ema-value N)` returns the live
  object, so the agent slices it and does not fetch it again.
- **No trace layer.** The agent checks each result live.
- **Docstrings are the documentation.** The prompt lists every tool with
  its first docstring line; `(ema-doc 'sym)` returns the rest.
- **The agent extends itself.** `ema-tool-save` stores a documented
  function in `~/.emacs.d/ema/tools/`; `ema-skill-save` stores a prose
  note in `~/.emacs.d/ema/skills/`. Both are listed in later
  conversations.
- **It works in front of you.** It reads your windows (`ema-view`),
  shows code (`ema-show`), edits with a highlight (`ema-edit`), puts long
  output in temporary buffers (`ema-present`) and asks in the minibuffer
  (`ema-choose`, `ema-confirm`).
- **Code intelligence** through eglot, xref, flymake and imenu
  (`ema-xref`, `ema-lsp`, `ema-diagnostics`, `ema-outline`).
- **Providers switch on the fly**, also in the middle of a conversation
  (`M-x ema-switch-provider`). A switch is never blind: the candidate
  configuration makes one real call through a separate adapter instance,
  and ema switches only when a tool call comes back.
- **It knows itself.** The prompt names its source files, its state
  directory and its limits. Ask it to change its model: it reads the
  provider's model list, offers options in the minibuffer
  (`ema-provider-propose`), tests your pick, then switches.
- **Review, not authorship.** `ema-note` puts review notes under lines;
  `ema-suggest` shows a diff that you accept or decline.
- **Emacs first, the shell last.** `ema-search` searches the project
  through xref, `ema-buffer-text` reads buffers and files, `ema-run`
  starts builds and checks in a compilation buffer without a freeze, and
  `ema-git` goes through magit when you have it (plain git otherwise).
  `ema-shell` remains for quick commands and stops after
  `ema-shell-timeout` seconds.
- **Shipped skills**, read on demand: `intro` (the map of what ema can
  do; ask "what can you do?"), `self` (how ema changes its own source)
  and `organizer` (plans, todos and the org agenda).
- **It changes itself behind a gate.** ema runs from a git checkout.
  `ema-self-check` compiles the source and runs the tests in a separate
  Emacs; `ema-self-reload` loads the files only after a pass. New
  abilities go to the state directory first (tools, actions, skills);
  the source is for core behaviour.
- **Organizer.** Each project keeps its plans in a `todo.org`
  (`ema-todo-add`, `ema-todo-state`, `ema-todos`). `ema-agenda-add`
  asks you, then puts the file on your global `org-agenda-files`; ema
  remembers it in its state directory and does not touch your init
  files.
- **Packages.** `ema-packages` and `ema-package-search` discover what
  exists; `ema-install` asks you first.

## Setup

```elisp
(add-to-list 'load-path "~/code/ema")
(require 'ema)
(setq ema-secrets-file "~/.config/ema/secrets.env")
```

The secrets file holds `NAME=VALUE` lines; the names are the `:key` of
each provider in `ema-providers`:

```
llm.key.anthropic=...
llm.key.openrouter=...
llm.key.openai=...
```

Every secret goes through `ema-secret-function`. Set it to another
function of one argument (the name) to move to auth-source, pass or a
keyring.

## Use

| Command | Key in the chat | What it does |
|---|---|---|
| `M-x ema` | | Open the chat in a side window |
| `M-x ema-ask` | | Ask from the minibuffer, from any buffer |
| `ema-send` | `RET`, `C-c C-c` | Send (`C-j` inserts a newline) |
| `ema-abort` | `C-c C-k` | Stop the running turn |
| `ema-continue` | `C-c C-r` | Call the model again after an error |
| `ema-switch-provider` | `C-c C-p` | Change provider or model |
| `ema-new` | `C-c C-n` | New conversation with a clean context; re-reads tools and skills |
| `ema-resume` | `C-c C-o` | Continue an earlier conversation of this project |
| `ema-forget` | | Delete a conversation from the history |

`C-g` stops a cell that runs too long.

## Keys in your code buffers

Bind the prefix map once:

```elisp
(keymap-global-set "C-c e" ema-command-map)
```

An active region is always what is sent. With no region, each command
uses its own scope.

| Key | Command | Sends |
|---|---|---|
| `C-c e a` | `ema-ask-here` | The line at point, with your question from the minibuffer |
| `C-c e c` | `ema-add-here` | Nothing yet: adds a reference to the chat input and moves there |
| `C-c e e` | `ema-act-explain` | The definition at point |
| `C-c e r` | `ema-act-review` | The definition; findings come back as notes on lines |
| `C-c e f` | `ema-act-refactor` | The definition; changes come back as diffs you accept |
| `C-c e x` | `ema-act-fix` | The line and its diagnostics |
| `C-c e d` | `ema-act-doc` | The definition |
| `C-c e u` | `ema-act-usages` | The symbol at point |
| `C-c e .` | `ema-act` | Pick an action from a list |
| `C-c e q` | `ema-clear-notes` | Removes the review notes |
| `C-c e ]` / `[` | `ema-next-note`, `ema-previous-note` | Moves between the review notes |
| `C-c e m` | `ema-menu` | A transient menu of all of the above, with your saved actions |
| `C-c e o` / `n` / `k` / `p` | | Open chat / new / stop / switch provider |

What "the code at point" is depends on the buffer
(`ema-context-functions`): lines in a code buffer, the section at point
in magit, the marked files in dired, the message at point with its
source in a compilation or grep buffer, the subtree in org.

More ways in and out:

- **Embark:** `embark-act`, then `z` asks ema about the region, symbol,
  definition or file; `Z` picks an action.
- **Links:** a file path in a reply (`src/parse.el:120`) is a link to
  that place. The chat's directory is the project root, so `M-n` in
  `C-x C-f` and `embark-act` also find the path at point.
- **Flymake:** where flymake is on, each review note is also a
  diagnostic.
- **Undo:** all edits of one turn in a buffer are one undo step.
  `M-,` returns to where you were before ema showed you a place.

An action is a pre-prompt plus a scope, stored as data. Ask ema for a
new one ("make me a shortcut that checks error handling"): it calls
`ema-action-save`, which defines `ema-act-NAME`, binds the key and saves
it in `~/.emacs.d/ema/actions.eld`.

## While a turn runs

- A spinner and the current activity show in the chat header and in the
  mode line of every window (`ema ⠹ waiting for the model, call 2`).
- The end of the chat shows the last cells of the turn, one line each
  (`✓ #7 (first line…)`), and a link to the live log.
- `*ema-cells*` (`C-c C-l`) is a read-only buffer with every cell and
  its full result, updated live. When the turn ends, the queue becomes
  one line (`▸ 7 cells, #1–#7`) that links into the log.

## Projects and history

- **One chat for each project.** `M-x ema` and the `C-c e` keys go to
  the chat of the current buffer's project: `*ema: NAME*`. Buffers
  outside a project share `*ema*`. All chats share one Emacs, so tools,
  skills and variables are common.
- **Everything is recorded** in `~/.emacs.d/ema/history.sqlite`
  (SQLite is built into Emacs): conversations with their project,
  messages, model calls with tokens and duration, cells with code and
  result. Set `ema-history-enabled` to nil to turn it off. The database
  holds what the model saw, file contents included; it stays on your
  machine.
- **The window.** ema sends the whole conversation until the input
  passes `ema-context-high` tokens (120k). Then the oldest turns leave
  the window, down to about `ema-context-low` (60k), and a note with
  your earlier requests takes their place. A trim costs one cache miss;
  between trims the prompt cache holds. Nothing is deleted.
- **Memory.** The same database has a `memories` table: short facts
  with a title of at most 200 characters, for one project or global.
  The prompt lists the newest titles (`ema-memory-window`: 15 global, 25
  of the project) and says how many more exist. ema saves, reads and
  searches them with `ema-memory-save`, `ema-memory`,
  `ema-memory-search` and `ema-memory-delete`.
- **ema reads its history** with `ema-history` (full-text search) and
  `ema-history-sql` (read-only SQL); the `history` skill has queries
  for the analysis of runs.

## Files

| File | Holds |
|---|---|
| `ema.el` | The cell evaluator, the chat buffer, the loop |
| `ema-llm.el` | Providers (Anthropic and OpenAI-compatible wire formats), secrets, HTTP |
| `ema-tools.el` | `ema-deftool` and the built-in tools |
| `ema-history.el` | The SQLite history: conversations, messages, calls, cells |
| `ema-self.el` | Provider test, switch and proposal; the saved configuration |
| `ema-org.el` | Todos in org files, the agenda |
| `ema-actions.el` | Context at point, the prefix keymap, the menu, actions |
| `skills/intro.md`, `self.md`, `organizer.md` | Skills that ema reads on demand |
| `skills/core.md` | The system prompt |
| `ema-tests.el` | `make test` |

## Safety

The agent evaluates arbitrary Emacs Lisp in your session with your
permissions. There is no sandbox. The prompt tells it to confirm before
an action that is hard to undo; nothing enforces that.
