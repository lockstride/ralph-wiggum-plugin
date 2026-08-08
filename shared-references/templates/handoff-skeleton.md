# Loop Handoff

> Rolling state document.
>
> - `## Last gate state` — rewritten by the plugin after every gate run.
> - `## Auto-enriched state` — appended by the plugin on ROTATE/TURN_END
>   (last commit, last `[x]` task, next unchecked task, and how old the
>   working set below is). Provides mechanical carry-over even when the
>   agent gets force-killed.
> - `## Working set` — yours. Add this section before yielding the turn
>   (current task, files in flight, ≤ 5 architectural facts) so the next
>   loop starts with your in-flight context, not just mechanical state.
>   REPLACE it in full each time — it describes the present, not the run's
>   history. Delete what is no longer true rather than writing above it.

## Last gate state

_(none yet)_
