# Moving to a new Mac

Move your agent chats and config to a new Mac in about an hour, with one file to carry. Code does not travel in the file: it travels through GitHub, so push it first.

## On the old Mac

1. **Push everything that is not pushed.** den clones these again on the new Mac, so local-only commits are lost:
   ```bash
   for d in ~/.config/opencode ~/.claude ~/.agents/skills; do git -C "$d" status -sb | head -1; done
   ```
   A line that says `ahead` means push it. Do the same for your project checkouts.
2. **Export the chats.** This writes a mode-600 tarball to `~/.local/state/den/exports/`. It holds Claude Code, Cortex and OpenCode history, and `~/.claude.json`, which can hold credentials, so treat it like a secret.
   ```bash
   den sessions export
   ```
   To leave work checkouts out of the export, set `DEN_SESSIONS_EXCLUDE` (space-separated globs) in `~/.config/den/local.env`.
3. **Carry the tarball** by AirDrop or a USB disk. Do not put it in a synced folder.

## On the new Mac

1. Run the one-liner from the [README](README.md#quick-start). Answer the preflight questions, then let it run.
2. Restore the chats. Import checks every path, takes a snapshot of what it replaces, and leaves your data untouched if the archive is bad:
   ```bash
   den sessions import ~/Downloads/agent-sessions-<stamp>.tar.gz   # the file you carried over
   ```
3. Check the result. `den doctor` is read-only:
   ```bash
   den doctor
   ```
4. Delete the tarball when the chats open.

## The old Mac, after

`den clean --dry-run` shows what den installed and would remove. Nothing goes until you run `den clean` and type `clean`.
