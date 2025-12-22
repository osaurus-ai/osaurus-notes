# osaurus-notes

An Osaurus plugin for Apple Notes.

This plugin allows AI models in Osaurus to interact with the Apple Notes app.

## Capabilities

The plugin exposes the following tools:

- `list_notes`: Get a list of notes (with content preview).
- `search_notes`: Find notes by text search.
- `create_note`: Create a new note (optionally in a specific folder).

## Requirements

- macOS
- Apple Notes app
- Osaurus app must have permission to control Notes (via Automation permissions in System Settings).

## Development

1. Build:

   ```bash
   swift build -c release
   ```

2. Package (for distribution):
   The release workflow automatically creates a zip file named `osaurus-notes-<version>.zip`.

   To manually package:

   ```bash
   cp .build/release/libosaurus-notes.dylib ./libosaurus-notes.dylib
   zip osaurus-notes-0.1.0.zip libosaurus-notes.dylib
   ```

3. Install locally:
   Load the plugin in Osaurus using the `osaurus-notes-0.1.0.zip` file.

## Permissions

On the first use, macOS will prompt you to allow Osaurus (or the terminal running it) to control "Notes". You must allow this for the plugin to function.
