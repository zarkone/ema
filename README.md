# ema

A minimal agent that lives in Emacs.

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
| `ema-new` | `C-c C-n` | New conversation; re-reads tools and skills |

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
| `C-c e o` / `n` / `k` / `p` | | Open chat / new / stop / switch provider |

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

## Files

| File | Holds |
|---|---|
| `ema.el` | The cell evaluator, the chat buffer, the loop |
| `ema-llm.el` | Providers (Anthropic and OpenAI-compatible wire formats), secrets, HTTP |
| `ema-tools.el` | `ema-deftool` and the built-in tools |
| `ema-self.el` | Provider test, switch and proposal; the saved configuration |
| `ema-actions.el` | Context at point, the prefix keymap, actions |
| `skills/core.md` | The system prompt |
| `ema-tests.el` | `make test` |

## Safety

The agent evaluates arbitrary Emacs Lisp in your session with your
permissions. There is no sandbox. The prompt tells it to confirm before
an action that is hard to undo; nothing enforces that.
