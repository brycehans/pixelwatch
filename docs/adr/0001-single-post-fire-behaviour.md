# Single post-fire behaviour (no cooldown / recurring mode)

A Watcher that fires always transitions to `triggered` and stays there until the user manually Arms it again (which captures a fresh baseline) or deletes it. There is no `.cooldown(N)` mode, no recurring fire, no automatic re-baselining.

We considered three alternatives during design: (a) the original two-mode design (`.autoPause` vs `.cooldown(seconds)` with timed re-baseline), (b) a "return-to-baseline gates re-arm" mode that avoided rebaselining mid-animation, and (c) this — one mode only. (a) had a pathological footgun: in `.cooldown(N)` mode a watcher pointing at animated content (spinner, progress bar) would re-baseline mid-frame and fire again immediately, looping forever. (b) fixed that but added a quiet failure mode (a watcher could sit in cooldown forever if the region drifted slightly past threshold and never returned). (c) trades automation for predictability — every fire is an acknowledgement, never a notification storm — and is the simplest possible thing.

Consequence: no `PostFireMode` enum, no `rebaselined` event, no `PostFireStage` beyond the trivial `thresholdExceeded → triggered` transition, no `WATCH_POST_FIRE` hook env var, no cooldown countdown UI, no "default post-fire mode" Settings field. The state machine drops from five states to four (`idle`/`armed`/`triggered`/`errored`).

Cost of reversing: meaningful — would require re-adding the enum, the event, the stage, the env var, the UI, and re-introducing the state. But the data model can absorb the addition without breaking persisted Watchers.
