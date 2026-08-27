Media Memory v0.1.3 hardens background processing against real-world storage conditions. Processing now pauses gracefully when a media source (for example a NAS volume or an authorization root) becomes unreachable, instead of marking every segment of that video as failed; a single actionable warning offers retry, reauthorize, or rescan recovery. Probe-duration drift no longer rebuilds finished videos: significant drift is corrected through a staged new segment generation that activates atomically, with the previous generation serving search until the new one is complete. Corrupt cached description rows now self-heal instead of failing a whole page, and descriptions awaiting regeneration against updated evidence are clearly marked in the UI. The sidebar now shows per-library statistics. This release also fixes a rare failure path that could stall background lanes after removing a library item, and adds 17 regression tests (126 total).

Upgrade notes from v0.1.2:

- The database migrates in place to schema v9 on first launch. No action is required and indexed data is retained.
- If a media volume goes offline during processing, the queue parks on that video without creating failed tasks. Bring the volume back, then use “重试读取源” in the warning popover, rescan the library, or reauthorize it from its context menu to resume.
- If a video's reported duration drifts after a system update while its content is unchanged, the affected video is re-segmented in the background; search stays available on the previous generation until the corrected one is activated.

The App remains self-signed and is not Apple-notarized. The signing private key and encrypted backup are not included in the repository, DMG, or Release assets.
