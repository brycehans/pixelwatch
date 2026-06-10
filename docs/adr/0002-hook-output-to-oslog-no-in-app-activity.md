# Hook output to OSLog; no in-app activity surface

Hook stdout and stderr are captured to OSLog under `subsystem=com.bryce.pixelwatch, category=hook` (tagged with watcher name + exit code; first ~4 KB of each stream). There is no in-app "Recent activity" view, no per-Watcher activity ring buffer in `WatcherStore`, and no right-click "Recent activity…" menu item. Users debug misbehaving hooks via `log show --predicate 'subsystem == "com.bryce.pixelwatch"' --last 1h`; users who want a persistent log of fires write a hook that does it themselves (`echo "$WATCH_AT $WATCH_NAME ..." >> ~/pixelwatch-fires.log`).

We considered three alternatives: (a) the original in-app Recent activity view, (b) drop hook output capture entirely, and (c) this — capture to OSLog only. (a) requires an in-memory ring buffer per Watcher plus a UI surface to render it, which contradicts the app's "shell-hook-only output, no in-app notification surface" philosophy and grows code/RSS without commensurate value. (b) is the absolute minimum but leaves users with no way to diagnose a silently-failing hook short of re-running it manually. (c) costs one `os_log` call per hook stream, gives users a system-native debugging path, and keeps the in-app surface minimal.

Consequence: `WatcherStore` does not hold activity history; the right-click menu has one fewer item; the Configure-sheet help text should mention the OSLog destination so users know where to look. PRD user story #23 is updated to reflect this; the implicit promise "the app is a shell-out, not a notification surface" is preserved.

Cost of reversing: small. Re-adding a ring buffer and a UI surface is an additive change. OSLog capture would coexist.
