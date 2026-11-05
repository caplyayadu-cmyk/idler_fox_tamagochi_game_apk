# Release notes

## v0.2.1

- Read the installed Android version from the package manager so older installs receive updates.
- Stream GitHub release APKs through Android DownloadManager with visible progress and cancellation.
- Verify the downloaded package, version, SHA-256, and signing certificate before opening Android's installer.
- Write saves atomically and recover the last complete save after an interrupted write.
- Preserve a damaged save file for recovery instead of silently replacing it.

## v0.2.0

- Added optional update checks from GitHub Releases.
- Added manual update check, integrity verification, and Android installer handoff.
