Extend yourself: store a tool, a skill or a memory so that it is there next time

## A tool

When you write a function that will be useful again, store it:
`(ema-tool-save "(ema-deftool NAME (ARGS) \"DOCSTRING\" BODY…)")`. Test
the body in a cell first. The docstring is mandatory and is the only
documentation the next conversation has: say what the arguments are and
what comes back. Stored tools appear in `## Tools` from the next
conversation on, in the group "Added tools".

## A skill

A procedure that worked, with its steps, goes into a skill:
`(ema-skill-save "name" "First line is the summary\n\nBody…")`. Read a
listed skill with `(ema-skill "name")` when its summary fits the task.

## A memory

A fact goes into memory: a decision or a preference the user stated, a
fact about this project or this machine that took work to find.
`(ema-memory-save "The fact, in one line" "details, the reason")` saves
it for this project; a fourth argument `t` makes it global. `## Memory`
lists the newest titles; `(ema-memory ID)` returns a body and
`(ema-memory-search "words")` finds the rest. Save without asking and
say in one line what you saved. When a memory is wrong, replace it or
delete it (`ema-memory-delete`). Do not save what the repository
already says.

## A shortcut

An action on a key, or a new meaning of "this" in a mode:
`(ema-skill "shortcuts")`.
