Secrets: set up the encrypted key file and add a provider key, without ever seeing a value

Use this when a model call fails with "no secret", when the user wants
another provider, or when they ask how keys work.

## The rules, first

- You never see a key. Never read, open, print or decrypt the
  auth-source file, in a cell or in a shell. Never ask the user to
  paste a key into the chat: the chat goes to the model provider and
  into the history.
- When a key reaches you by accident, say so at once and tell the user
  to revoke it at the provider.
- `ema-buffer-text` and the context keys refuse an auth-source file or
  a `.gpg` file. Do not go around that with other functions.
- The user types a key only into the minibuffer of
  `(ema-secret-ask "NAME")` or of their own `M-x ema-secret-set`.

## How ema finds a key

A provider names its key (`llm.key.anthropic`). ema asks auth-source
for the entry whose machine is that name. The entry is one line in the
encrypted file:

    machine llm.key.anthropic login ema password VALUE

An environment variable works too (`LLM_KEY_ANTHROPIC`), for scripts.

## Step 1: look

`(ema-secrets-status)` shows the auth-source files, whether gpg is
there and has a key, where a new secret goes, and which provider keys
are present. It shows no value. It can make Emacs ask the user for
their GPG passphrase: tell them before you call it.

## Step 2: close the gaps, one at a time

| The status says | Do |
|---|---|
| gpg: not installed | The user installs GnuPG with their system's package manager. Offer the command; they run it |
| 0 secret keys | They choose: a GPG key (below), or a file protected by a passphrase alone. Explain both in two lines and let them pick with `ema-choose` |
| No .gpg file in auth-sources | With a yes (`ema-confirm`), `(add-to-list 'auth-sources "~/.authinfo.gpg")` for this session. Give them the line for their init file; do not edit the init file yourself |
| The file does not exist yet | Nothing to do: the first save creates it |
| A provider key is missing | Step 3 |

A GPG key: the user runs this in a terminal, because it asks for a
passphrase that you must not see:

    gpg --quick-generate-key "Their Name <their@mail>" default default never

A passphrase alone: at the first save, Emacs asks which keys to encrypt
for. With no key selected it asks for a passphrase and encrypts the
file with that.

When Emacs seems to hang at a save or a read, the passphrase prompt is
somewhere the user cannot see. `(setq epg-pinentry-mode 'loopback)`
makes the prompt appear in the minibuffer; with gpg 2.1 or later the
agent also needs `allow-loopback-pinentry` in `~/.gnupg/gpg-agent.conf`.
Check the variable before you suggest it.

## Step 3: add the key

1. Tell the user where the key comes from (the provider's console) and
   what will happen: a hidden prompt in the minibuffer, then a question
   from Emacs about the save.
2. `(ema-secret-ask "llm.key.NAME")`. It returns "saved in FILE" or
   "cancelled".
3. Emacs may ask "Save auth info to file …?": the answer is `y`.
4. Check it with `(ema-provider-test 'NAME)`: one real call. Then
   switch with `ema-provider-switch` if they want that provider.

## Replace or remove a key

`ema-secret-ask` adds a line; auth-source uses the first match. To
replace a key, the user opens the file themselves (`C-x C-f`, Emacs
decrypts it), deletes the old line and saves. Tell them to do this
while the chat window does not show that buffer, and do not look at it.
