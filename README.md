# Idler Fox Android releases

This repository contains release instructions and small release metadata only. The Godot sources, player data, signing keys and APK files are excluded. APKs and manifests are GitHub Release attachments.

1. Keep the previous signing key outside both repositories. Increase Android `version/code` and Godot `config/version_code` together. Update the Android version name and add the matching tag to `CHANGELOG.md`.
2. With the Android template installed, build and verify locally from PowerShell 7:

   ```powershell
   .\prepare_release.ps1 -Tag v0.2.3 -GodotExe "C:\path\to\Godot_v4.7.2-stable_win64_console.exe"
   ```

   The builder uses signing environment variables and temporarily adds the updater to the generated Android template. After inspecting the APK and checking the certificate, package and version, it replaces `idlerfox.apk` and generates `latest.json`. Failed builds keep the previous APK. The default build does not contact GitHub.
3. Install over the previous APK with isolated player data and test the update and persistence. To upload a draft, repeat the preparation command with `-UploadDraft`, or attach the reviewed local files to a draft in GitHub.
4. Publish with `./publish_release.ps1 -Tag v0.2.3` only after reviewing the draft. The command compares both remote attachment hashes and sizes before making the release public. Corrections after publication require a new version and tag.

The game checks `https://github.com/caplyayadu-cmyk/idler_fox_tamagochi_game_apk/releases/latest/download/latest.json`. Each manifest points to an APK under its own tag. If the repository moves, update the repository constants in both the Android updater and Godot, plus the release commands.
