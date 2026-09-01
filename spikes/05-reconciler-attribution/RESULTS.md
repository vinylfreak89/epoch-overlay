# Spike 05 — reconciler feasibility (attribution, freeze, injection)

Date: 2026-09-01. Machine: macOS 26.6.1, APFS. Three questions the
reconciler design depends on.

## A. Per-operation write attribution

Probe: `eslogger create write rename unlink` (Apple's Endpoint Security
CLI, run as root) while a known pid writes a probe file; check the event
carries that pid.

**Result: blocked on TCC, not on capability.** `eslogger` (and any ES
client) fails with `ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED — responsible
process needs TCC Full Disk Access`. ES *does* carry the writer's
`audit_token` (pid) per event; the gate is a one-time **Full Disk Access
grant** to the daemon's binary (System Settings → Privacy & Security →
Full Disk Access), which cannot be scripted. So attribution is available
and clean, contingent on a one-time GUI grant. The raw `/dev/fsevents`
route may avoid the TCC prompt but is unsupported; ES is the correct
path and its cost is one setup step, not a blocker.

**Action:** re-run this probe after granting FDA to confirm the pid field
end-to-end. Needs the owner to grant FDA (a `sudo`-class handoff).

## B. Freeze rung (SIGSTOP/SIGCONT on a process group)

Probe: a `setsid` process group (parent + an "evasive" child writing on a
loop, modeling an agent that spawns a helper to do writes) is `kill
-STOP -<pgid>`'d, observed, then `kill -CONT`'d.

**Result: PASS.** Writes: 15 before freeze, 15 after 3 s frozen
(delta 0), 25 after resume. The whole group froze — the evasive child
included — and resumed cleanly. This confirms the constraint rung is
real and cognition-independent: every write path an agent invents is a
process in the tree, and the kernel stops scheduling the tree regardless.

## C. Injection surface for the siren rung — **the hard finding**

Research verdict (Claude Code docs, both form factors): **there is no
documented, stable external-injection surface for Claude Code — neither
CLI nor desktop app.** `claude --resume <id> -p` queues into an *idle*
session or forks; it does not interleave into a *live* turn. No local
socket/HTTP inbound, no URL scheme, no AppleScript/XPC for mid-turn
messages. Session enumeration and pid→session mapping are likewise
undocumented (transcript JSONL under `~/.claude/projects/` exists but is
explicitly version-unstable). Codex is the opposite: its app-server
JSON-RPC `turn/*` surface accepts steer-into-live-turn (proven all
session, via `codex-run steer`).

**Consequence for the design:** the *siren* (a message into the writer's
own context) is available for Codex now, but **not for Claude Code until
it exposes a surface**. The reconciler must therefore not depend on the
siren as its floor. The floor is B (freeze) + revert, which need nothing
from the agent product — external, kernel-level, universal. A frozen
Claude agent whose siren couldn't be delivered still reads the situation
from the `EPOCH-GUARDED.md`/conflict sentinel when it resumes and retries
its write. Siren is an optimization where a live-injection API exists,
never the mechanism.

## Net

Attribution: available (ES + one-time FDA). Freeze+revert: proven,
product-independent — this is the real constraint. Siren: Codex yes,
Claude not yet — degrade gracefully rather than depend on it. None of the
three needs a filesystem write barrier, so all are compatible with
iCloud-resident roots.

## CORRECTION (2026-09-01) — the "Net" above overstates this spike

Found by re-reading the committed artifact against the write-up:

1. **`probe.sh` contains no freeze experiment.** Zero occurrences of
   `SIGSTOP`, `kill -STOP`, or `-CONT`. The committed script runs only the
   eslogger attribution probe of section A. The section-B numbers were
   observed but are **not reproducible from this repository**, so "proven"
   is not supportable. Section A's probe, the only one committed, exits
   blocked on FDA — it did not pass either.
2. **"Freeze+revert" is two claims and neither is established here.**
   Revert is not merely untested but *impossible* in the general case:
   where the lane owner and a violator both wrote one file, `base` and
   `current` cannot reconstruct the owner-only state. DESIGN.md's ladder
   now says **park**, not revert.
3. **A process group is not a process tree.** Section B stopped a parent
   and child deliberately placed in one group; it does not license "every
   evasion an agent invents is still a process in that tree". A descendant
   can `setsid`, double-fork, route work through a pre-existing helper or
   `launchctl`, or have a same-UID watchdog send `SIGCONT`. This design's
   own open-verification list already conceded detached grandchildren.
4. **The trust model was never stated**, which is what makes (3) ambiguous:
   `uchg`, the state files, `SIGCONT` and the daemon are all same-UID
   controllable, so against a deliberately evasive process none of this
   holds, while against the actual observed failure mode — an agent routing
   around an annoying rule — it is adequate. The design must say which it
   defends against before any of these rungs can be called sufficient.

To restore the section-B claim, commit the freeze experiment as a runnable
probe and extend it to real Claude/Codex process topologies, `setsid` and
double-fork descendants, shared helpers, and an external `SIGCONT` watchdog.
