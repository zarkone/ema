Change your own source: where a change goes, and the test gate before a reload

You run from source. `ema-source-directory` is a git checkout of your
own code; `(ema-self-files)` lists the files and what each holds.

## First decide where the change goes

| The user wants | Put it in | How |
|---|---|---|
| A new capability | A stored tool | `ema-tool-save` |
| A new shortcut | An action | `ema-action-save` |
| "This" to mean something in another mode | A context function | `ema-tool-save`, then add it to `ema-context-functions` |
| Know-how, a preference, a fact about this machine | A skill | `ema-skill-save` |
| A different limit or default | A variable (`ema-max-turns`, `ema-digest-limit`, `ema-digest-full-limit`, `ema-request-timeout`, `ema-tools-daily-count`) | set it; tell the user the line for their init file |
| Different core behaviour: the loop, the chat buffer, the adapters, a built-in tool, the prompt | The source | the procedure below |

Prefer the upper rows. They are in the state directory, they take
effect at once and they survive an update of the source. Change the
source only when no upper row can do the job, and say so.

## Procedure for a source change

1. Read the code first: `ema-outline`, `ema-buffer-text`, `ema-search`
   in `ema-source-directory`.
2. `(let ((default-directory ema-source-directory)) (ema-git "status"
   "--short"))`. When there are changes that are not yours, tell the
   user before you start.
3. Propose each change with `ema-suggest`, one focused change at a
   time. The user is the author of ema too.
4. Add or update a test in ema-tests.el for behaviour that changed.
5. Save the buffers, then `(ema-self-check)`. It compiles the files and
   runs the tests in a separate Emacs, so that a broken file cannot
   break the session you run in. Read the outcome with
   `(ema-run-result "self-check" 30)`.
6. Fix until the status is "finished" and no test fails. A compile
   warning is a finding: fix it.
7. `(ema-self-reload)`. It refuses when the check did not pass or when a
   source file changed after the check. The new code is live from your
   next cell.
8. Try the change live once.
9. When the change adds, removes or alters a capability, update
   README.md, skills/intro.md and, for behaviour rules, skills/core.md.
10. Commit with `ema-git` when the user says so: one topic, one commit,
    only the files you changed, by path.

## When it goes wrong

- The check fails and you cannot fix it: say so, show the failure, and
  offer `(ema-git "checkout" "--" FILE)` after an `ema-confirm`.
- The live session misbehaves after a reload: the user runs
  `M-x ema-restart` after a `git stash` or a checkout of the last good
  commit. Tell them this before a risky change to ema.el.
- Never reload source that did not pass the check.
