# PowerShell fork changelog

PowerShell-only changes layered on top of upstream claude-pace (`claude-pace.ps1`).
For the canonical bash changelog see [CHANGELOG.md](CHANGELOG.md); the `## Synced to`
headers below mark which upstream version the PowerShell port has caught up to.

The established PowerShell visual differences from bash (bracket bar, ASCII pace
signs, compact countdown, token count, etc.) are documented in
[.claude/powershell.md](.claude/powershell.md) under "Visual diffs from bash".

## Synced to upstream 0.9.1

- Color the effort word to match Claude Code's own Dark-theme effort palette via
  truecolor (`\e[38;2;R;G;Bm`): low=amber `255,193,7` (warning), medium=green
  `78,186,101` (success), high=periwinkle `177,185,249` (permission), xhigh=violet
  `175,135,255` (autoAccept), max=rainbow-red `235,95,87`. Claude Code animates
  xhigh (shimmer) and max (rainbow cycle); the statusline uses a static stand-in.
  Replaces the prior dim→bold-red intensity ramp. Needs a truecolor-capable terminal.
