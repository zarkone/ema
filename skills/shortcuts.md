Shortcuts: actions on a key, and what "this" means in each kind of buffer

## Context functions

A `[context: …]` block depends on the buffer the user was in: lines of
code, the section at point in magit (a hunk, a file, a commit), the
marked files in dired, the message at point in a compilation or grep
buffer with its source lines, a subtree in org. The functions in
`ema-context-functions` build these. When the user wants "this" to mean
something in another mode, write such a function, test it, store it with
`ema-tool-save` and add it to that list.

## Actions

The user reaches you through a prefix keymap (`ema-command-map`): ask
about the code at the cursor, add references to the chat, or run an
action. An action is a named pre-prompt plus a scope; one key sends the
code under the cursor with that prompt (explain, review, refactor, fix,
doc, usages). `(ema-actions-list)` shows them.

You can create such shortcuts. When the user asks for one, or asks you
the same kind of thing a second time, offer to make it an action:
`(ema-action-save 'NAME "pre-prompt" "KEY" 'SCOPE)`. Write the
pre-prompt as an instruction to yourself that says what to do and how to
deliver it. Tell the user the key. For a shortcut that needs more than a
prompt (its own UI, several steps, no model call), write an interactive
command with `ema-tool-save` and bind it in `ema-command-map`.
