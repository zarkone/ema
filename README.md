# ema

A minimal agent that lives in your Emacs. It helps you write and
review code. So it's more like an integrated helper, not an autonomous
agent. Moves you closer to the code, slows you down a little bit.

The model has one tool: an Emacs Lisp cell that runs in your live
session. It sees your windows, uses your packages and answers
through your buffers, your minibuffer and your keys.

I decided to distribute it as source code, not as package, with the
idea that when you need something you just extend `ema` in place.

## Core capabilities

| Area | What ema does | Tools |
|---|---|---|
| **See** | Reads your windows, buffers, point and region. What "this" means follows the buffer: lines of code, a magit hunk, marked files in dired, a compiler message, an org subtree | `ema-view`, `ema-buffer-text`, `ema-context-functions` |
| **Understand** | Definitions, references, diagnostics and outlines through eglot, xref, flymake and imenu; text search that honours the project's ignore rules | `ema-xref`, `ema-diagnostics`, `ema-outline`, `ema-lsp`, `ema-search` |
| **Point** | Shows a place beside the chat, writes `path:line` links in replies, puts long output in a buffer | `ema-show`, `ema-present` |
| **Review** | One note under each line with a finding; where flymake is on, the note is also a diagnostic | `ema-note` |
| **Change** | Proposes a diff that you accept or decline; edits directly only what you dictate. All edits of a turn are one undo step | `ema-suggest`, `ema-edit` |
| **Ask** | Options and yes/no questions in the minibuffer | `ema-choose`, `ema-confirm` |
| **Run** | Builds, tests and linters in a compilation buffer, without a freeze; git through magit when you have it | `ema-run`, `ema-git`, `ema-shell` |
| **Plan** | Plans and todos in a `todo.org` for each project; offers the file to your global org agenda | `ema-todo-add`, `ema-todos`, `ema-agenda-add` |
| **Remember** | Every conversation, model call and cell goes to SQLite. Short facts are kept as memories, for a project or global | `ema-history`, `ema-history-sql`, `ema-memory-save` |
| **Grow** | Stores new tools, shortcuts and know-how; changes its own source behind a test gate | `ema-tool-save`, `ema-action-save`, `ema-skill-save`, `ema-self-check` |
| **Switch models** | Lists, tests and switches providers and models in the middle of a conversation | `ema-switch-provider`, `ema-provider-propose` |

Ask ema "what can you do?": it reads its own `intro` skill and answers
for the buffer you are in.

## How it works

- **One tool.** The model calls `eval` with Emacs Lisp. Everything
  else is an ordinary documented function.
- **Emacs is the persistent kernel.** What a cell defines stays
  defined. A long result is cut and stored; `(ema-value N)` returns the
  live object, so ema slices it and does not fetch it again.
- **Docstrings are the documentation.** A new tool needs only a
  docstring to be known.
- **Tools are discovered, not listed.** The prompt gives a full line
  (signature and first docstring line) only to the tools that the
  history shows as most used. It names the others under their group; a
  group is the `;;;;` heading above the tool in the source. ema reads
  the rest when it needs it: `(ema-tool-group "NAME")` returns the
  signatures of a group and `(ema-doc 'NAME)` the whole docstring. A
  call that fails shows the documentation of the tool, so a wrong
  guess costs one turn.
- **Skills are read on demand.** The prompt lists each skill with one
  line. Shipped: `intro` (the map of capabilities), `organizer` (plans,
  todos, the agenda), `history` (queries over earlier runs), `secrets`
  (the setup of your keys), `self` (how ema changes itself), `providers`
  (switch the model), `packages`, `shortcuts` (actions and context
  kinds), `extend` (store tools, skills and memories).
- **Emacs first, the shell last.** ema searches, reads files, runs
  checks and calls git through Emacs. `ema-shell` remains for quick
  commands and stops after `ema-shell-timeout` seconds, because a
  synchronous command freezes Emacs.

## Install

ema needs Emacs 29 or later (built-in SQLite). It is developed on
Emacs 31. magit, embark, eglot, flymake and org are optional: ema uses
each one when you have it.

ema runs from source, so that it can read and change itself. Clone it
and load it:

```elisp
(add-to-list 'load-path "~/code/ema")
(require 'ema)
(keymap-global-set "C-c e" ema-command-map)
```

### Keys for the model providers

ema reads its keys through auth-source, from the GPG-encrypted file in
your `auth-sources` (usually `~/.authinfo.gpg`). The entry of a key has
the key's name as the machine:

```
machine llm.key.anthropic login ema password sk-ant-...
```

The names are the `:key` of each provider in `ema-providers`:
`llm.key.anthropic`, `llm.key.openrouter`, `llm.key.openai`.

`M-x ema-secret-set` adds a key: you pick the name and type the value
into the minibuffer. The value is not shown and goes straight to the
encrypted file. ema refuses to save into a file that is not encrypted.

No GPG setup yet? Ask ema "help me set up my keys": its `secrets` skill
checks what you have and leads you through it. ema never reads the file
and never sees a value; it asks you to type it (`ema-secret-ask`).

An environment variable also works, for scripts: `LLM_KEY_ANTHROPIC`.
Every secret goes through `ema-secret-function`; set it to another
function of one argument (the name) to read from pass or a keyring.

## Keys

### In your buffers

An active region is always what is sent. With no region, each command
uses its own scope.

| Key | Command | What it does |
|---|---|---|
| `C-c e a` | `ema-ask-here` | Asks your question about the line at point |
| `C-c e c` | `ema-add-here` | Adds a reference to the chat input; repeat it to collect places |
| `C-c e e` | `ema-act-explain` | Explains the definition at point |
| `C-c e r` | `ema-act-review` | Reviews it; findings come back as notes on lines |
| `C-c e f` | `ema-act-refactor` | Proposes a refactoring as diffs |
| `C-c e x` | `ema-act-fix` | Fixes the line, with its diagnostics |
| `C-c e d` | `ema-act-doc` | Writes the missing documentation |
| `C-c e u` | `ema-act-usages` | Finds the usages of the symbol at point |
| `C-c e .` | `ema-act` | Picks an action from a list |
| `C-c e m` | `ema-menu` | A transient menu of all of this, with your own actions |
| `C-c e ]` `[` `q` | | Next note, previous note, clear the notes |
| `C-c e o` `n` `h` `k` `p` | | Open the chat, new conversation, resume, stop, switch model |

With embark: `embark-act`, then `z` asks ema about the region, symbol,
definition or file, and `Z` picks an action. `M-,` returns to where you
were before ema showed you a place.

### In the chat

| Key | Command | What it does |
|---|---|---|
| `RET`, `C-c C-c` | `ema-send` | Sends (`C-j` inserts a newline) |
| `M-p`, `M-n` | | Earlier and later inputs |
| `C-c C-k` | `ema-abort` | Stops the running turn; `C-g` stops one cell |
| `C-c C-r` | `ema-continue` | Calls the model again after an error |
| `C-c C-n` | `ema-new` | New conversation with a clean context |
| `C-c C-o` | `ema-resume` | Continues an earlier conversation of this project |
| `C-c C-l` | `ema-cells` | The log of all cells with their results |
| `C-c C-p` | `ema-switch-provider` | Changes the provider or the model, after a test call |

A file path in a reply is a link. The chat's directory is the project
root, so `M-n` in `C-x C-f` and `embark-act` also find a path at point.

### While a turn runs

- The chat header and the mode line show a spinner, and the status text
  a tool set with `ema-status`.
- The end of the chat shows the last cells of the turn, one line each,
  as links into the log.
- After the turn, the cells become one line (`▸ 7 cells, #1–#7`). The
  chat keeps your messages and the replies.

## Projects, history and memory

- **One chat for each project.** `M-x ema` and the `C-c e` keys go to
  the chat of the current buffer's project, `*ema: NAME*`. Buffers
  outside a project share `*ema*`. All chats share one Emacs, so tools,
  skills and variables are common.
- **History.** `~/.emacs.d/ema/history.sqlite` records each
  conversation with its project, the messages, every model call with
  tokens and duration, and every cell with code and result. ema
  searches it (`ema-history`) and queries it with read-only SQL
  (`ema-history-sql`). Ask "which tools did you use most last week?" or
  "what did we decide about the parser?".
- **The window.** ema sends the whole conversation until the input
  passes `ema-context-high` tokens. Then the oldest turns leave the
  window, down to about `ema-context-low`, and a note with your earlier
  requests takes their place. Between trims the prompt cache holds.
  Nothing is deleted; `M-x ema-forget` deletes a conversation.
- **Memory.** Short facts live in the same database, for one project
  or global: a decision you stated, a preference, a fact that took work
  to find. The prompt lists the newest titles and counts the rest. ema
  saves one and tells you in one line.

The database holds what the model saw, file contents included. It
stays on your machine. Set `ema-history-enabled` to nil to turn it off.

## Make it yours

ema extends itself, and each extension is plain data or plain Lisp in
`~/.emacs.d/ema/`.

| You want | Ask ema, or use | It is stored as |
|---|---|---|
| A new capability | `ema-tool-save` | A documented function in `tools/` |
| A shortcut for a request you repeat | "make me a shortcut that checks error handling" | An action: a pre-prompt, a scope and a key in `actions.eld` |
| "This" to mean something in another mode | A function in `ema-context-functions` | A stored tool |
| A procedure to follow next time | `ema-skill-save` | A Markdown note in `skills/` |
| A fact to remember | `ema-memory-save` | A row in the database |
| Another model or endpoint | `M-x ema-switch-provider`, `ema-provider-add` | `config.eld` |
| A change to ema's core | "change yourself so that …" | A commit in the source checkout |

For a change to its own source, ema proposes each edit as a diff, then
compiles and runs the tests in a separate Emacs (`ema-self-check`).
`ema-self-reload` loads the new code only after a pass.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `ema-provider` | `anthropic` | The fallback provider. The one in use is stored per project (`ema-switch-provider`) and as the default (`ema-switch-default-provider`), in the `project_config` table; `.dir-locals.el` may set `ema-provider` and `ema-model` and wins over both. The mode line marks `[project]` or `[.dir-locals.el]` |
| `ema-secret-store-file` | nil: the first `.gpg` file in `auth-sources` | Where `ema-secret-set` saves a key |
| `ema-max-turns` | 40 | Model calls for one message before ema stops and asks |
| `ema-context-high`, `ema-context-low` | 120000, 60000 | The window, in input tokens |
| `ema-memory-window` | `(15 . 25)` | Memory titles in the prompt: global and project |
| `ema-tools-daily-count` | 12 | Tools with a full line in the prompt; the others are names in groups |
| `ema-tools-daily-min-uses` | 5 | Recorded cells that call a tool before it counts as much used |
| `ema-shell-timeout` | 10 | Seconds before `ema-shell` stops a command |
| `ema-digest-limit` | 4000 | Characters of a cell result that the model sees |
| `ema-display-action` | a side window | Where the chat opens |
| `ema-history-enabled` | `t` | Record conversations |

## Files

| File | Holds |
|---|---|
| `ema-llm.el` | Providers (Anthropic and OpenAI-compatible wire formats), secrets, HTTP |
| `ema-tools.el` | `ema-deftool`, the tool list of the prompt and the built-in tools |
| `ema-review.el` | Notes on lines, suggested changes that you accept or decline |
| `ema-history.el` | The SQLite history and the memories |
| `ema-self.el` | Provider test and switch, the self check, the saved configuration |
| `ema-org.el` | Todos in org files, the agenda |
| `ema-cell.el` | The cell evaluator: runs one cell and builds its result for the model |
| `ema-chat.el` | The chat buffer: its state, the transcript, the input, the header, the cell queue |
| `ema.el` | The conversation: the commands, the turn (model call, reply, cells), the window, resume |
| `ema-actions.el` | Context at point, the prefix keymap, the menu, actions |
| `skills/core.md` | The fixed part of the system prompt; the tool, skill and memory lists are generated |
| `skills/*.md` | Skills that ema reads on demand |
| `ema-tests.el` | The tests: `make test`; `make compile` checks for warnings |

The table is in load order. Each file starts with a map of its own
parts, and `ema.el` starts with the path of one turn through the code.

## Safety

ema evaluates arbitrary Emacs Lisp in your session with your
permissions. There is no sandbox. The prompt tells it to confirm before
an action that is hard to undo. Installs and agenda changes ask you in
the minibuffer. A suggestion shows a diff and waits for `y` or `n` in
the diff buffer; you can read other buffers first. Nothing else
enforces that. Use
it where you would let a colleague type at your keyboard.
