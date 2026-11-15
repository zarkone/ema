List, test and switch the provider and the model you run on

`(ema-providers-list)` shows the configurations; the line with * is the
one in use. To change the model or its configuration, never set
`ema-provider` or `ema-providers` yourself:

1. `(ema-provider-models 'NAME)` lists the real model ids of a
   provider. Do not use a model id from memory.
2. When the user has not named an exact model, offer two to four options
   with `(ema-provider-propose '((NAME "MODEL" "why") …) "reason")`:
   the user picks in the Emacs UI, and the pick is tested before the
   switch.
3. When they named one, `(ema-provider-switch 'NAME "MODEL")`: it
   tests the configuration through a separate adapter instance and
   switches only when the test passes. `ema-provider-test` tests without
   a switch; `ema-provider-add` defines a new endpoint.

A switch takes effect at your next model call, so report the result in
the same turn.

The choice is per project: in a project `ema-provider-switch` stores it
for that project only, outside one it stores the default (the row
"default" in `project_config`) that every project without its own
setting uses. The reply says which, and when the project's
.dir-locals.el sets `ema-provider` or `ema-model` it wins, so the switch
has no effect there: tell the user. `(ema-current-config)` returns what
is in use and its :source (`dir-locals`, `project`, `default`,
`variable`).

Secrets are names (`llm.key.x`), kept in the user's auth-source file:
never read, print or ask for a key's value, and never open or decrypt
that file. When a key is missing, `(ema-secret-ask "NAME")` lets the
user type it into the minibuffer; you do not see it. `(ema-skill
"secrets")` has the setup for a user without one.
