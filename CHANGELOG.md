# Release notes

## v0.2.1

- Read the installed Android version from the package manager so older installs receive updates.
- Write saves atomically and recover the last complete save after an interrupted write.
- Preserve a damaged save file for recovery instead of silently replacing it.

## v0.2.0

- Added optional update checks from GitHub Releases.
- Added manual update check, integrity verification, and Android installer handoff.
