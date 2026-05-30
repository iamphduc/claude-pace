# PowerShell impl (`claude-pace.ps1`)

Fork add-on for Windows. PS 7+, no Bash/jq. Same statusline contract.

Wire: `pwsh -NoProfile -File <path>/claude-pace.ps1` in `statusLine.command`.

## Visual diffs from bash

Tuned for Windows terminals (Consolas, OEM codepages):

- Bar `[###-------]` — brackets share threshold color (vs `█░`).
- Pace delta `(+51%)` red / `(-6%)` green — paren-wrapped ASCII signs (vs Unicode `⇡⇣` which fail in many Win fonts).
- Countdown compact `1h32m` / `2d4h` (vs largest unit only).
- Primary `%` bold (`\e[1m`).
- Effort word colored to match Claude Code's own Dark-theme effort palette via truecolor (`\e[38;2;R;G;Bm`): low=amber `255,193,7` (warning), medium=green `78,186,101` (success), high=periwinkle `177,185,249` (permission), xhigh=violet `175,135,255` (autoAccept), max=rainbow-red `235,95,87`. CC animates xhigh (shimmer) / max (rainbow); we use a static stand-in. Bash leaves `MODEL EF` all cyan — no per-effort color.
- Token count `340K` dim next to `%` (= `PCT × CTX / 100`). Buckets: `<1000` → `850`, `<1M` → `<int>K`, `≥1M` → `<int>M`.
- Labels `5h:` / `7d:` colon.
- Inter-window dim `|` between 5h/7d → line 2 has **2 pipes**.
- Symmetric `$GAP=2` chars each side of central `|`.
- Untracked file lines fold into `+` count + `Nf`. Bash ignores untracked. Binary (NUL byte) → file but no lines. 1 MiB per-file cap. Respects `.gitignore` via `--exclude-standard`.

## Parity with bash

Same invariants:

- Cache root: `$XDG_RUNTIME_DIR` → `$LOCALAPPDATA\claude-pace` → `$HOME\.cache\claude-pace`. Never `/tmp`/`%TEMP%`. None safe → `$CACHE_OK = $false`.
- Cache record: `[char]0x1F` between fields, legacy `|` on read. **Wire-compat with bash caches.** (Only git-info cache now; quota cache was removed in v0.9.0.)
- Quota: stdin `rate_limits` only. Absent → `5h --` / `7d --` + session cost. **No cache fallback** — see `docs/decisions/2026-05-20-quota-cache-removal.md` for why. Legacy `claude-sl-quota` files from v0.8.x are orphans, ignored.
- Atomic writes: tmp + `Move-Item -Force` (atomic on NTFS within volume).
- Single `ConvertFrom-Json` for stdin. Settings JSON read once into var, validated.

## PS gotchas (bit me, easy to miss)

- **Variable names case-INSENSITIVE.** `$d` ≡ `$D`. Local `$d` (days count) once shadowed `$D` (dim ANSI) in `Format-Usage` → "22d 5h" with no dim instead of "2d 5h". Use distinct names: `$days`/`$hours`/`$mins`. Test 11b regression.
- **Force UTF-8 output.** `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)` at script start. Without → multibyte chars reinterpreted as OEM codepage (cp1252/cp437) → render `?`. Same in `test.ps1` for parent capture.
- **Single-elem array auto-unwrap.** `Write-Output -NoEnumerate` preserves array shape. Otherwise `$arr[0]` on string returns first char (`"Claude"[0]` → `'C'`). See `Invoke-Statusline` in `test.ps1`.
- **NTFS symlink tests need admin.** Bash tests 16/32/33 skipped/adapted.
- **No bash arith injection.** PS uses `[int]::TryParse`, strict validation. Test 13 skipped intentionally.

## Tests

`test.ps1` — custom harness, no Pester. 79+ assertions across 29 scenarios mirror `test.sh`. Run: `pwsh -NoProfile -File test.ps1`. Exit = failure count. `Invoke-Statusline` save/restores `CLAUDE_CODE_AUTO_COMPACT_WINDOW` alongside the cache-root env vars so Test 29 cases don't leak the window into each other (or into baseline tests).
