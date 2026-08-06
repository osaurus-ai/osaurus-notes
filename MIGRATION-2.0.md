# Migrating to osaurus-notes 2.0

Version 2.0 replaces title-oriented, raw-payload tools with an ID-based,
paginated contract. Tool results now appear under the canonical success
envelope's `result` field.

## Tool mapping

- `list_notes(limit)` → `query_notes(limit)`
- `search_notes(query)` → `query_notes(query)`
- Use `get_note(id)` to retrieve a complete note body.
- `create_note(title, body, folder?)` keeps its name but now returns only the
  stable `id` and actual `folder`.

The plugin exposes exactly `query_notes`, `get_note`, and `create_note`.

## Query results

Each query item contains `id`, `title`, `preview`, `preview_truncated`,
`folder`, `created_at`, and `modified_at`. The result also contains `returned`,
`total`, `truncated`, `next_cursor`, and `partial_failure_count`.

Use `next_cursor` unchanged in a follow-up call. Use the returned stable `id`
for `get_note`; titles are not unique.

## Folder behavior

An explicit `folder` must match an existing Apple Notes folder exactly. Missing
folders now return `not_found`. Version 2.0 no longer falls back silently to the
default folder and no longer creates or treats `Claude` or `Test-Claude`
specially.

If `folder` is omitted for creation, Apple Notes chooses its normal default
destination and the plugin reports the actual folder.

## Errors and permissions

All tools return explicit canonical Osaurus success or failure envelopes and
canonical host failure kinds. The local compatibility envelope shim was
removed.

The manifest now declares the actual `automation` requirement. The permission
policy remains `ask`.
