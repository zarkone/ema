Read earlier conversations and analyze runs in the SQLite database

Every conversation is recorded in one database, history.sqlite in the
state directory: the messages as they went to the model, each model call
with tokens and duration, each cell with code and result. Each
conversation carries its project root. Nothing is ever archived
elsewhere; old rows stay there.

Use it when the user refers to earlier work ("as we did last week"),
when the start of this conversation is no longer shown to you, and when
they ask how ema behaves (which tools, how many calls, what failed).

## Tools

- `(ema-conversation)`: the id and the project of this conversation.
- `(ema-history "words")`: full-text search in this project; a second
  argument `t` searches all projects.
- `(ema-history-sql "select …")`: one read-only SELECT. Its docstring
  has the schema: read it with `(ema-doc 'ema-history-sql)`.

## When the start of the conversation is not shown

A long conversation is sent from a later message on, with a note that
lists the user's earlier requests. The rest is in the database:

    select seq, role, substr(content, 1, 300) from messages
    where conversation = ID and seq < 40 order by seq

    select n, substr(code, 1, 200), substr(result, 1, 300) from cells
    where conversation = ID order by n

Read only the rows you need. Do not load a whole conversation.

## Queries for the analysis of runs

Conversations of a project, newest first:

    select id, datetime(started, 'unixepoch', 'localtime'), title, model
    from conversations where project = 'ROOT' order by started desc

Cost of a conversation:

    select count(*), sum(tokens_in), sum(tokens_cached), sum(tokens_out),
           sum(ms) / 1000 from calls where conversation = ID

Which tools the cells call, most used first (the first symbol of a cell):

    select substr(code, 2, instr(code || ' ', ' ') - 2) as fn, count(*)
    from cells where conversation = ID group by fn order by 2 desc

Cells that failed, and slow cells:

    select conversation, n, ms, substr(code, 1, 120), substr(result, 1, 200)
    from cells where status = 'error' order by time desc limit 20

    select conversation, n, ms, substr(code, 1, 120) from cells
    order by ms desc limit 10

Model calls that failed:

    select conversation, model, error, datetime(time, 'unixepoch', 'localtime')
    from calls where error is not null order by time desc limit 20

Behaviour before and after a change to ema (the source commit is on each
conversation):

    select c.ema_commit, count(distinct c.id), count(x.id),
           sum(x.status = 'error')
    from conversations c join cells x on x.conversation = c.id
    group by c.ema_commit

## Report

Put a table of results in a buffer with `ema-present`; give the chat the
two or three numbers that answer the question.

The user resumes a conversation with `M-x ema-resume` and deletes one
with `M-x ema-forget`. You do not delete history.
