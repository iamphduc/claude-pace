# Decision: Remove last-known quota cache fallback

**Date:** 2026-05-20
**Status:** Accepted (shipped in v0.9.0)
**Supersedes:** `docs/superpowers/specs/2026-04-13-quota-cache-fallback-design.md`, `docs/superpowers/plans/2026-04-13-quota-cache-fallback.md`

## Context

v0.8.1 introduced a private quota cache so claude-pace could reuse the last stdin `rate_limits` snapshot when a later run lacked the field (`HAS_RL=0`). Cache file: `~/.cache/claude-pace/claude-sl-quota`, one global record per machine.

PR #14 (kvdb, 2026-05-19) reported provider cross-contamination: the user runs Claude Max in some sessions and Microsoft Foundry in others. The Foundry session triggered the `HAS_RL=0` path, read back the Max snapshot from the shared cache, and displayed the wrong account's quota. The PR proposed switching to a per-project hashed filename (`claude-sl-quota-<sha1(project_dir)>`).

## Decision

Remove the quota cache fallback entirely. When `rate_limits` is absent from stdin, claude-pace shows `--` placeholders for 5h/7d and may still surface the session cost. No more cache writes, no more cache reads.

## Rationale

5h/7d quota is account-level data. The cache key must therefore identify the **account/provider**, not the project. stdin gives us no reliable provider/account identifier, so any cache write cannot prove it belongs to the current session at read time.

Per-project hashing (PR #14) reduces one common collision pattern (different providers in different projects) but does not solve the underlying identity gap:

- Two providers in the same project still collide.
- A provider that omits `rate_limits` reads back another provider's snapshot whenever they share a project hash.
- Accumulating per-project cache files trades one form of contamination for orphan-file growth in `~/.cache/claude-pace/`.

Displaying `--` is an honest failure mode. Displaying another account's quota is a silent wrong answer. For a quota tracker, silent wrong answers are worse than placeholders.

Removing the fallback also collapses ~250 lines of code+tests covering symlink hardening, partial-snapshot rejection, expired-reset guards, and atomic rewrite semantics. None of that complexity has any value once we accept that the cached payload's provenance cannot be verified.

## What changes for users

- Claude Code `>=2.1.80` (the supported floor since v0.8.0) always provides `rate_limits`; the common case is unaffected.
- Sessions where `rate_limits` is absent (older Claude Code; providers that omit the field) now show `--` for 5h/7d quota and the session cost when available.
- Existing `~/.cache/claude-pace/claude-sl-quota*` files are ignored from v0.9.0 on. Safe to delete manually.

## When this could be reintroduced

Only when stdin carries a stable provider/account identifier (something like `account.id`, `subscription.id`, or `provider.kind`). With that key, a per-account cache record becomes verifiable, and the silent-wrong-answer failure mode disappears. Until then, the fallback stays out.

## Acknowledgment

Bug reported by @kvdb in [PR #14](https://github.com/Astro-Han/claude-pace/pull/14). The PR was closed in favor of removal; the underlying problem was real and surfaced the design flaw described above.
