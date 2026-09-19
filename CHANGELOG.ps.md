# PowerShell fork changelog

PowerShell-only changes layered on top of upstream claude-pace (`claude-pace.ps1`).
For the canonical bash changelog see [CHANGELOG.md](CHANGELOG.md); the `## Synced to`
headers below mark which upstream version the PowerShell port has caught up to.

The established PowerShell visual differences from bash (bracket bar, ASCII pace
signs, compact countdown, token count, etc.) are documented in
[.claude/powershell.md](.claude/powershell.md) under "Visual diffs from bash".

## Synced to upstream 0.9.4

- Port the auto-compact first-frame fix (upstream 0.9.2, issue #15 follow-up). CC
  sends `context_window.total_input_tokens` as `0` on a fresh session's first
  frame, and the port only recomputed against the auto-compact window when that
  value was `> 0` — so the bar (and its `1M` label) flashed the full window until
  the first API response. `$TIN` now uses a `-1` sentinel when the field is absent
  (old CC) and keeps a present `0`, and the gate is `$TIN -ge 0`, so a fresh-session
  first frame measures against the cap from the start while an omitted field still
  falls back to the full window.
- Port the disposable-cache-write fix (upstream 0.9.3, PR #17). `Save-CacheRecord`
  wrote to a `claude-sl-tmp-*` GUID file then `Move-Item`d it into place; CC cancels
  the script mid-run, so a cancellation between the two stranded a temp file
  forever. Records now write straight to the final path — a torn write is just a
  cache miss the reader sanitizes and the next run recomputes. Reparse points are
  refused explicitly, because `[IO.File]::WriteAllText` follows a symlink to its
  target (as bash's `>` does), where `Move-Item -Force` used to replace the link.
- 0.9.4 (install from tagged releases) is bash/plugin distribution plumbing and
  needs no PowerShell change; merged for the shared channels.

## Synced to upstream 0.9.1

- Color the effort word to match Claude Code's own Dark-theme effort palette via
  truecolor (`\e[38;2;R;G;Bm`): low=amber `255,193,7` (warning), medium=green
  `78,186,101` (success), high=periwinkle `177,185,249` (permission), xhigh=violet
  `175,135,255` (autoAccept), max=rainbow-red `235,95,87`. Claude Code animates
  xhigh (shimmer) and max (rainbow cycle); the statusline uses a static stand-in.
  Replaces the prior dim→bold-red intensity ramp. Needs a truecolor-capable terminal.
