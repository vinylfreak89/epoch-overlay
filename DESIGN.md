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

### Lifecycle binding (revised 2026-08-29, owner decision: no hooks)

The original convergence bound epochs to Claude `PreToolUse`/`Stop` hooks.
The owner rejected that constraint — per-harness hooks break the
transparency invariant. Tier 1 therefore splits into two independent
layers:

**Ambient layer (the new build — zero agent configuration).** A daemon
(LaunchAgent) watches enrolled roots via FSEvents. It takes a `clonefile`
checkpoint whenever a root goes quiescent, so a pre-burst base exists by
construction before any write activity; when a burst ends it produces the
`base → current` review diff. This covers *every* writer — Claude, Codex,
sub-agents, the human in a bare shell — with no hooks, no wrappers, and no
per-tool latency. Its reviews say what changed, not who; attribution
exists only where the cooperative layer was engaged. If the daemon was
down when a burst began, the diff is computed against the older base and
the review must say so.

**Guard layer (owner-identified 2026-09-01, verified in spike 04).** For
hand-picked roots *outside iCloud scope*, tier 1 gains real mechanical
enforcement with no overlay and no attribution: the root is
`chflags uchg` (user-immutable, recursively) while idle. Any writer that
never heard of the protocol hits a kernel `EPERM` and finds
`EPOCH-GUARDED.md` in the root explaining exactly how to proceed;
`epochctl begin` snapshots, unflags, and records the owner; `end` diffs
and re-flags (including files created during the epoch); `recover`
re-flags after a crash. Flag flips cost ~0.01 s per few hundred entries.
Bypass requires a deliberate `chflags nouchg` — a knowing act, not an
oversight. `guard` refuses FileProvider-managed roots unconditionally
(sync-down writes would hit the same EPERM, and uchg is Finder's lock
bit, which iCloud propagates) — verified live on this machine, where
`~/Documents` is actively synced CloudDocs. Consequence: tier 2's
exclusive value narrows to protection *during* open epochs and true
three-way publication; idle-state protection — the common case — is
kernel-enforced by tier 1.

**Cooperative layer (retained, not rebuilt).** The existing `codex-run`
tree lock remains the mutual-exclusion mechanism, extended inside that
skill rather than replaced by a new hook system. Placement rule: a lane is
acquired at a chokepoint *every* turn of a controller surface passes
through, regardless of initiator — for Codex that is Wheelhouse's turn
submission path (GUI-typed and Claude-dispatched alike; verify where
typed turns actually enter before wiring it). Claude's own turns and raw
human shells have no such product chokepoint and rely on the ambient
layer (explicit `epochctl begin` remains available for deliberately risky
work). Two hardening notes carried over from the epoch semantics, to
apply to the lock where feasible: contention should refuse loudly rather
than warn-and-proceed, and a dead owner should park for explicit
recovery rather than expire on age.

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

## The reconciler (converged tier-1 enforcement, 2026-09-01)

A **program, not an agent** — the owner's framing — that closes the loop
on every write to a guarded root. It supersedes both the hook idea and
sandbox-coupling (each rejected as convention disguised as constraint:
anything the writer's own harness configures, or that depends on the
writer's cognition, gets optimized away — the observed failure mode being
an agent routing around an annoying write-style rule by writing a python
script to do the edit).

Model: **land → attribute → reconcile.** Interception is explicitly
rejected — nothing intercepts writes without breaking sync or an
eliminated mechanism. A write lands; the reconciler knows who wrote it
within seconds; unowned writes are confronted and every landed byte is
revertible from the checkpoint.

Components:

1. **Attribution daemon** (root, installed once via the audited sudo
   path): consumes the kernel's raw event stream (`/dev/fsevents`, which
   carries the writing pid — the user-level FSEvents API strips it),
   filtered to guarded roots. Endpoint Security is the blessed future
   substitute once the paid account and entitlement exist.
2. **Reconciler** (user-level): registry of roots and lanes, process-tree
   registrations from agent surfaces, checkpoint/diff engine (epochctl's
   logic), policy, and the escalation ladder.
3. **Agent adapters speaking each product's API directly** — Codex's
   app-server JSON-RPC and Claude Code's session surface — never through
   a personal bridge, so switching agent products swaps an adapter, not
   the architecture. Each adapter must cover **both form factors of its
   product** — the CLI and the desktop app — for injection, session
   enumeration, and process-tree registration alike; a surface that only
   reaches one form factor is a partial adapter, not a solution.

Escalation ladder for a write without the lane:

1. **Siren** — a message injected mid-turn into the writer's own context:
   "you don't own this root; stop and establish provenance." Cheap;
   catches the good-faith case. Cognition-dependent, so never the last
   rung.
2. **Freeze** — continued unowned writes ⇒ `SIGSTOP` the writer's process
   group. Kernel-level, writer-non-overridable, filesystem-untouched.
   Every evasion an agent invents is still a process in that tree.
   `SIGCONT` only after adjudication (take the lane, or revert and
   release).
3. **Revert** — the post-hoc window's writes are diffed against the
   checkpoint and reversible; reverts follow the contract (loud, never
   silent).

**The human is a first-class writer**: saving a file in a root an agent's
epoch owns triggers a bright actionable alert — who owns it, since when,
[let it finish] [interrupt it] [take over] — the brief's
authority-precedence UI, generalized. Humans are sovereign: sirens and
alerts, never freezes.

**Bypass allowlist, non-negotiable**: fileproviderd/bird (CloudDocs
prune, hydrate, download, metadata), Spotlight, Time Machine and peers
are never sirened, frozen, or counted as violations — their activity is
reconciled as sync/system churn via the three-way rule. Attribution is
precisely what makes this exemption possible.

Open verifications: `/dev/fsevents` per-op pid on 26.6.1 (root spike);
SIGSTOP/SIGCONT behavior against live Claude/Codex turns; Claude Code's
stable external-injection surface; process-tree attribution reliability
for detached grandchildren.

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
