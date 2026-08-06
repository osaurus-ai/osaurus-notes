---
name: osaurus-notes
description: Use when the user asks to browse, search, read, or create notes in Apple Notes.
---

# Apple Notes

Use `query_notes` to discover notes by optional text or exact folder. Continue
with `next_cursor` when more results are needed.

Use `get_note` only after discovery and identify notes by `id`, never by title
alone. Fetch full bodies only when needed.

For creation, omit `folder` unless the user named an existing folder or prior
results established it. Do not guess a folder or silently substitute another
one. Confirm the title, body, and requested destination before calling
`create_note`.

Treat a nonzero `partial_failure_count` as an incomplete query even when the
call succeeds.
