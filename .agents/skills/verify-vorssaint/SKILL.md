---
name: verify-vorssaint
description: Verify Vorssaint menu-bar features and restoration on a disposable macOS developer profile.
---

# Verify Vorssaint

Draft: live macOS journeys are blocked on Linux. Read `README.md`,
`CONTRIBUTING.md`, `build.sh` and [the feature index](features/README.md). Use a separate
macOS 14+ Apple Silicon test account and isolated worktree. Check active owners,
memory, CPU and free disk before build. Record revision, OS, permissions,
developer bundle identity, test files and settings snapshot.

Developer builds can create a local signing identity if none exists. This task
does not authorize signing-identity or permission changes. Have the test Mac
operator establish the disposable profile and signing prerequisites under
separate authority before building.

On the supported test Mac, run `./build.sh --dev` for the developer build, then
`./build/VorssaintDeveloper --selftest` and `./build.sh --test` separately.
The `--test` branch exits after tests and does not produce the app bundle. Inspect its output for the produced bundle path,
then open that exact developer bundle. Do not use `--install`, replace the
daily-driver app, or grant permissions on Max's profile. Require the developer
menu icon and Settings to open before actions. T3 preview cannot prove native
macOS interactions; use an operator with desktop access and bounded observations.

Run the feature groups serially. Use temporary apps, files, snippets and
captures. Record original volume, outputs, keyboard/mouse preferences, display
levels and keep-awake settings before changing them. Skip destructive cleaner,
uninstaller, Homebrew, process-kill and OS shortcut actions unless an explicitly
disposable target and cleanup boundary exist. Never use production agent logs
or secrets as fixtures.

After surprising failure, restore only owned settings, confirm the app is ready,
and retry once. Quit the developer app and confirm owned helpers exit. Restore
all system settings and permissions changed for this run. Remove only owned
files and developer-profile state, keeping redacted evidence in ignored
`.agents/artifacts/<run-id>/`. Report physical audio/display observations
separately from test runner, CI, review and merge results.
