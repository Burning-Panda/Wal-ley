# wal-ley

A simple macOS app for looking at and editing SQLite files.

- Open a `.sqlite`, `.sqlite3` or `.db` file
- Browse tables, views, columns and indexes
- Sort, filter and page through rows
- Edit cells, delete rows, then save or discard
- Run your own SQL in a console

## Install

Download the `.dmg` from the Releases page and drag wal-ley to Applications.

Releases are not notarized unless the maintainer has set up an Apple Developer ID, so macOS may say the app "is damaged" or "can't be opened". The file is fine; macOS is blocking a download it can't verify. Clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/wal-ley.app
```

## Build

Open `wal-ley.xcodeproj` in Xcode and run. Needs macOS 14 or later.

## Release

The version lives in `VERSION`. From a clean, up-to-date `main`:

```bash
task bump-patch NOTES="What changed in this release"
```

Use `bump-minor` or `bump-major` for bigger bumps. This commits the new `VERSION`, tags `vX.Y.Z` with your notes as the tag message, and pushes. The Release workflow builds and publishes it, using the notes as the release description.
