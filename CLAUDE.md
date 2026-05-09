# CLAUDE.md

claude-pace = Claude Code statusline. Two impls:

- `claude-pace.sh` — Bash + jq, canonical (mac/Linux). Edit → read `.claude/bash.md` first.
- `claude-pace.ps1` — PowerShell 7+, fork add-on (Windows). Edit → read `.claude/powershell.md` first.

## Common commands

- Bash tests: `bash test.sh` (37+ scenarios). Lint: `shellcheck claude-pace.sh test.sh`.
- PS tests: `pwsh -NoProfile -File test.ps1` (95+ assertions, no Pester).
- Smoke: `echo '<json>' | bash claude-pace.sh` OR pipe stdin into `pwsh -NoProfile -File claude-pace.ps1`.
- Release (bash only): bump version in `.claude-plugin/plugin.json` + `npm/package.json`, update `CHANGELOG.md`, tag, publish GitHub Release. `publish.yml` auto-runs `npm publish`.
