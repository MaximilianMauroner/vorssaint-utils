# Alpha plugin test checklist

Import the ready package at `Tests/Fixtures/VorssaintAlphaTest.vorssaint-plugin` in **Settings → Features → Plugins**.

1. Confirm the import review shows the plugin name, version, seven commands, one `plugtest` search provider, all six capabilities, and three settings. Import it. It must remain disabled.
2. Enable it. Confirm the full trust warning appears before code can run.
3. Change the string, Boolean, and number settings. Run `Plugin Test: Run All hello`. Confirm a status appears and the clipboard contains JSON with the argument and all three settings.
4. Run `Plugin Test: Storage first`, then `Plugin Test: Storage second`. The second result must mention the first stored value.
5. Run the copy, status, open-docs, and no-message commands. Confirm each completes without freezing the Command Bar.
6. Run the expected-error command. Confirm `Expected alpha test error` is visible and a later command still works.
7. Search `plugtest hello`. Confirm the complete and minimal result rows appear. Check the subtitle, SF Symbol, multiple action rows, and every action.
8. Search `plugtest empty`, `plugtest error`, and `plugtest fetch`. Confirm empty, error, and network result states. Start `plugtest slow`, then replace the query. Confirm cancellation is quick and the next command works.
9. Disable the plugin while a search is active. Confirm its rows and shortcuts disappear and its process stops. Re-enable it through a new trust review.
10. Import the same package as an update. Confirm it is disabled and requires trust again. Test Restore Previous Version and confirm the restored version is also disabled.
11. Remove the plugin without deleting data, reinstall it, and confirm stored data remains. Remove it again with data deletion, reinstall it, and confirm storage is empty.
12. Disable the Plugins source in Command Bar settings. Confirm no plugin commands or search results appear and assigned plugin shortcuts do not run.

The expected-error and slow-search cases intentionally fail. They verify recovery, deadlines, and cancellation.
