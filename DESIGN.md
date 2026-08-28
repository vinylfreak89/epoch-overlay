# Epoch overlay — converged design

Status: **v1.0 — converged** (Claude ⇄ Codex design exchange, 2026-08-29).
The observable semantics live in `CONTRACT.md`; evidence in `spikes/` and
`RESEARCH.md`. Decision history is in git.

## Shape

Writers never own canonical. Any unit of work — a Claude turn, a Claude
sub-agent, a Codex thread — is a writer of equal standing; canonical is a
trunk that advances only through reviewed publications; precedence is
publication order, not writer identity. Isolation is **temporal** (epochs),
because per-process views at one path are unavailable on macOS without
mechanisms the owner has ruled out (see *Eliminated routes*).

Scope ceiling: the user directory (`~`). System paths are never touched.
iCloud is a pure compatibility constraint: fileproviderd must keep seeing
and syncing canonical content normally.

The design is two tiers plus documented extensions. Tier 1 ships first.

## Tier 1 — serialized in-place epochs (build now)

Not an overlay, and not claimed to be: a per-root cooperative writer lane,
an APFS copy-on-write checkpoint, in-place native writes, and a durable
review at the end. Its safety comes from serialization plus undo evidence.

Lifecycle per enrolled root:

1. Resolve the enrolled root; its canonical real path must be within `~`.
2. Atomically acquire the root's writer lane (nested/overlapping registered
   roots count as one lane conflict).
3. Recursively `clonefile` the root into the control store as `base`.
   This is snapshot-*like*, not an atomic volume snapshot: O(entries), and
   consistent only because the lane is held before traversal begins.
4. Only after the clone completes may the writer mutate canonical, at
   original absolute paths — full transparency, native APFS performance,
   and iCloud untouched (no mount exists; fileproviderd sees canonical).
5. On the terminal event, capture the `base → current` diff as the epoch's
   review record; retain the checkpoint; release the lane.

Honest limits, stated plainly:

- `result == current` by construction; "publication" is retrospective
  review. Bytes were visible in canonical throughout the epoch.
- A lane-violating concurrent writer is **invisible**: its changes are
  indistinguishable from the owner's in the diff. Tier 1 cannot attribute
  or detect that conflict.
- A tier-1 "park" can park the lane and the recovery decision; it cannot
  claim conflicting bytes were never published.

### Event boundaries

Claude Code (hooks carry `agent_id`, so the lane owner is the actual work
unit, not the conversation):

- **Open** lazily at the first potentially mutating `PreToolUse` (Bash,
  edit/write tools, and unknown filesystem-capable tools count as writers);
  the hook completes lane acquisition and the base clone before the tool
  runs.
- **Close** on `Stop` (main unit) / `SubagentStop` (sub-agent), after the
  review diff is captured.
- Lost session or failure → state `orphaned`; the lane is **not** released.
- No reentrant parent privilege: a parent yields its epoch before handing
  same-root writable work to a sub-agent; same-root sub-agents serialize; a
  child that cannot be put behind the lane is read-only for that root.

Wheelhouse/Codex:

- **Open** synchronously before the bridge forwards `turn/start` (waiting
  for the async `turn/started` notification would race; that notification
  only binds the turn id to the already-open epoch).
- **Close** on `turn/completed` / `turn/failed`, after review.
  `turn/interrupt` is not terminal — hold the lane until the terminal
  notification.
- `bridge/disconnected` → `orphaned`.

### Lane state and crash recovery

State lives outside projects, e.g.
`~/Library/Application Support/Wheelhouse/Epochs/` (excluded from any
enrolled root that contains it). One atomic lane directory per root:
canonical root + filesystem identity, epoch and work-unit ids, controller
and pid/process-start identity, turn/agent ids, base location, state
(`opening | active | reviewing | orphaned | closed`), timestamps for
diagnosis only.

Acquisition is atomic directory creation. **No TTLs; age is never grounds
to steal a lane.** On crash/disconnect: mark `orphaned`, keep the lane
closed, verify recorded process/turn state, produce the durable
`base → current` recovery diff, and require an explicit human/agent action:
resume the same owner, adopt current, restore selected content from base,
or abandon the checkpoint and release. No terminal event ⇒ no automatic
release.

## Tier 2 — the actual overlay (enforcement, later)

A covering mount over the root for the duration of the epoch:

- writes land in a branch; ordinary path traversal cannot mutate canonical;
- a crash leaves `base` and the branch both intact;
- a lane violator contaminates the reviewable branch, not canonical;
- publication finally has independent `base` / `result` / `current`, so the
  loud, parked, self-describing conflicts of `CONTRACT.md` become fully
  real.

Qualification (spike 01): pre-existing directory fds write *through* a
covering mount, so "canonical frozen" is approximate and tier 2 keeps the
full three-way check.

Engine choices — implementation details, not core dependencies, in order of
preference: **FSKit** path-backed module (macOS 26.0+ `FSPathURLResource`,
non-root `mount -F`), **fuse-t** (kext-less localhost NFS, vendor-signed —
no developer account needed to use), or a **thin VM as overlay engine
only** — a guest exporting a filesystem the host mounts; no Claude, Codex,
Wheelhouse, or bridge process ever runs in that VM.

Spike 03 verdict (26.6.1): fskitd is healthy — the 26.1/26.2
unprivileged-client bug is gone, and the registration/enablement pipeline
works for a hand-built module. The gate is signing:
`com.apple.developer.fskit.fsmodule` is a restricted entitlement (AMFI
kills ad-hoc binaries carrying it) and the capability is **not offered to
free personal teams** — FSKit module development requires a paid Apple
Developer Program membership. Enrollment is deliberately deferred: the
viability question is answered and does not expire, tier 1 needs no
engine, and the membership buys nothing until tier-2 development actually
begins. Enroll at that point (or earlier if fuse-t proves inadequate);
`spikes/03-fskit-health/` is the ready starting point. The membership
changes engines only — it does not add per-operation attribution to
FSKit, so the epoch shape stands regardless.

iCloud rule for tier 2: an engine is ineligible wherever its covering mount
would cause fileproviderd to traverse branch state or lose access to
canonical; such a root simply stays tier 1 until an engine demonstrates
compatibility. Branch stores are never located in synced areas.

## Eliminated routes (owner constraints, or verified impossible)

| route | status |
|---|---|
| per-process views from one FSKit mount | impossible — Apple: "FSKit does not support process attribution"; corroborated by SDK inspection and AgentFS source verdict |
| macFUSE kext | eliminated — no boot-security downgrade / untrusted drivers on Apple Silicon |
| agent-in-VM / container-per-writer | eliminated — agents, Wheelhouse, and the bridge stay host-side |
| iCloud as mechanism or sync channel | never proposed; iCloud is compatibility-only |

## Out-of-scope extensions (documented, not planned)

For the day genuine same-root parallelism justifies their weight:
**path-encoded attribution + chroot** (one mount exposes each branch as a
full-root subtree; a privileged launcher chroots each writer into its
branch, restoring original absolute paths; heavyweight — the chrooted
process still needs usable system paths); **Endpoint Security** write-gating
(pid-attributed deny, cannot branch content; restricted entitlement);
**second-uid NFS** (rejected for the symmetric model — uids don't scale to
N sub-agents). Adopted ideas from AgentFS: CloneEager materialization,
`clonefile` copy-up, whiteouts; its `bindProcess` is confirmed *not* a
macOS attribution mechanism.

## Next spike (agreed)

Tier-1 lifecycle prototype on one representative root: atomic lane
acquisition, tree clone, modify/create/delete/rename/symlink/xattr at
original paths, `base → current` capture, then **kill the owner mid-epoch**
and verify restart reports an orphaned lane with a usable recovery diff
rather than releasing it. Measure clone time and metadata growth.
