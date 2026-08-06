# osaurus-notes

An Osaurus 2.0 plugin for browsing, reading, and creating Apple Notes.

## Tools

- `query_notes(query?, folder?, limit?, cursor?)` browses or searches notes and
  returns stable IDs, titles, bounded previews, folders, timestamps, pagination
  metadata, and a partial-failure count.
- `get_note(id)` returns a note's complete body and metadata by stable ID.
- `create_note(title, body, folder?)` creates a note and returns its stable ID
  and actual destination folder.

Use `query_notes` for discovery and `get_note` only for notes whose full content
is needed. An explicit folder must already exist; missing folders return
`not_found`. Omitting `folder` lets Notes choose its default destination.

All results use explicit canonical Osaurus success or failure envelopes.
Arguments and result fields use snake_case.

## Requirements and permissions

- macOS 13 or newer
- Apple Notes
- Automation permission for Osaurus to control Notes

Every tool retains the `ask` permission policy because reading or mutating
personal notes through Apple Events is approval-sensitive.

## Development

```bash
swift package resolve
swift build -c release --product osaurus-notes
swift test
```

The release workflow packages the dynamic library together with `README.md` and
`SKILL.md`. See [MIGRATION-2.0.md](MIGRATION-2.0.md) for breaking changes from
1.x.
