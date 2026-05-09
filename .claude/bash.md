# Bash impl (`claude-pace.sh`)

Hot path, ~300ms tick. Top-to-bottom pipeline:

1. Read stdin → bail `Claude` if empty.
2. Parse stdin + `~/.claude/settings.json` in **one** `jq` call (TSV → shell vars). Never 2nd jq call.
3. Resolve private cache: `$XDG_RUNTIME_DIR/claude-pace` or `~/.cache/claude-pace`. Mode 700, owned, not symlink. None safe → caching off. Never `/tmp`.
4. Git via cache (5s TTL, atomic write). Reject corrupted records before arithmetic.
5. Quota snapshot cache (`claude-sl-quota`).
6. Format two lines, symmetric `|` align, emit.

## Quota cache fallback (only stateful piece)

Stdin `rate_limits` (CC 2.1.80+). Missing → reuse last fully-valid live snapshot if both resets future. Rules tests enforce:

- Only complete future-reset snapshots written (`_valid_quota_snapshot`).
- Partial payloads (missing `five_hour`/`seven_day`/`resets_at`) **never** overwrite cache.
- Expired/malformed cache rejected wholesale → both windows `--`.
- Session cost shown only if no quota — **suppressed on cache hit**.
- Cache rewrite tmp + rename. Symlink replaced not followed.

Spec: `docs/superpowers/specs/2026-04-13-quota-cache-fallback-design.md`.

## Cache record format

Single-line, ASCII Unit Separator (`$'\037'` = `SEP`) between fields. Legacy `|` parsed on read for back-compat. New fields at end. Branch names with `|` must round-trip — regression test exists.

## Output align invariant

Both lines one `|`, same column. Script measures plain-text width (no ANSI), pads shorter, then wraps color. `assert_aligned` checks across model/effort lengths.

## Pace delta

Per window (5h=300m, 7d=10080m): `delta = used% − elapsed%`. Positive = overspending (red ⇡), negative = surplus (green ⇣), zero = no arrow. Sign inverted in 0.6.0 — don't re-invert.

## Distribution surfaces

Same `claude-pace.sh` ships 3 channels — verify all 3 work on edits:

- **Plugin**: `.claude-plugin/plugin.json` + `commands/setup.md`. `/claude-pace:setup` curls from `main`, writes `statusLine`.
- **npx**: `npm/cli.js` + `npm/package.json`. `prepublishOnly` copies `claude-pace.sh` into `npm/`. CI mirrors via `publish.yml`.
- **Manual curl**: README.md, raw `main` URL.

Versions in `.claude-plugin/plugin.json` + `npm/package.json` must sync.

## Constraints

- **Win Git Bash compat**: `jq --slurpfile` + `<(...)` silently fail (no `/proc/<pid>/fd/N`). Use `--argjson` + shell var. See 0.8.6 changelog, `_SETTINGS=$(cat ...)` pattern.
- **`set -f` intentional** — disables glob so unquoted `$DIR` can't expand into filename lists. Don't remove.
- **No 2nd jq call.** Every field extracted in single jq invocation ~line 138.
- **Never write `/tmp`.** No safe cache root → `CACHE_OK=0`.
- **Quota stdin-only** since 0.8.0. Old Usage API fallback removed. Don't re-introduce network calls.
- **Effort resolution**: stdin `effort.level` (CC 2.1.119+) → settings `effortLevel` → `"medium"`. Word not glyph (0.8.5). `MODEL EF` capped 28 chars.
