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

Model: **land → attribute → reconcile.** A write lands; the reconciler
knows who wrote it within seconds; unowned writes are confronted.

> **RETRACTED 2026-09-01.** This paragraph previously read "Interception is
> explicitly rejected — nothing intercepts writes without breaking sync or
> an eliminated mechanism", and "every landed byte is revertible from the
> checkpoint". Both claims are wrong, and both were load-bearing.
>
> **Interception exists.** Endpoint Security exposes synchronous
> *pre-operation* gates — verified against this machine's MacOSX26 SDK: 44
> `ES_EVENT_TYPE_AUTH_*` events including `AUTH_OPEN`, `AUTH_CREATE`,
> `AUTH_TRUNCATE`, `AUTH_RENAME`, `AUTH_UNLINK`, `AUTH_CLONE`, `AUTH_MMAP`,
> each carrying a `deadline` the client must answer before. The kernel
> suspends the caller until it answers. That is interception at original
> paths, with no kext, no mount, and no VM. The error was not ignorance —
> ES is listed under *Out-of-scope extensions* — but **dismissal against the
> wrong requirement**: it was ruled out for "cannot branch content", i.e.
> judged against the strong contract's concurrent-writers-and-merge, when
> the requirement that matters here is only "keep unowned writers out of
> canonical". Branching is not needed for that.
>
> **Selective reversion is impossible** (Codex, 2026-09-01). Attribution
> yields actor and path, never each actor's prior bytes. If `base` is X, the
> lane owner produces A, and an unowned writer then produces A+B, neither
> `base` nor `current` can reconstruct A: restoring base destroys authorized
> work, keeping current keeps the violation. "It lands, it is attributed, it
> is undone" therefore cannot hold, and promising it contradicts
> CONTRACT.md's no-silent-resolution rule. The ladder's rung 2 is corrected
> to **park** below. Note the consequence: this partly reverses spike 04's
> conclusion that tier 2 had become less urgent — if tier 1 cannot cleanly
> undo a violator, the covering mount is again the thing that delivers the
> contract. Restoring the revert promise would need per-path content
> journaling during an open epoch (not designed, not costed).
>
> ES costs, recorded so this is not re-litigated optimistically: there is no
> `ES_EVENT_TYPE_AUTH_WRITE` (absent in both the 14.4 and 26.x SDKs), so the
> gate sits at open/create/rename/unlink/truncate/mmap and an fd opened
> before the policy applies still writes through — the same bypass class
> spike 01 found for covering mounts. Deadlines are hard, so policy must
> decide in milliseconds: deny-and-explain, never park-and-ask-a-human. A
> dead ES client fails **open**, so protection vanishes silently exactly
> when the daemon dies. And the entitlement is **discretionary Apple
> approval**, not merely the paid program — see *Open shape question*.

Components:

1. **Attribution daemon** (root, installed once via the audited sudo
   path). Transport corrected 2026-09-01: this said `/dev/fsevents` with
   ES as a "blessed future substitute", which contradicted spike 05 (raw
   fsevents unsupported; ES correct) and contradicted the ladder below in
   the same document. **ES is the transport**; `audit_token` carries the
   writer pid. Its NOTIFY events need only a Full Disk Access grant, so the
   entire policy layer — can fileproviderd/Spotlight churn be separated
   from an agent write, at what event volume, with what gaps — is testable
   *without* the restricted entitlement. Only the allow/deny flip needs it.
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

Escalation ladder for a write without the lane (floor first, verified in
spike 05):

1. **Freeze (the floor, the actual constraint)** — an unowned write ⇒
   `SIGSTOP` the writer's process group. Kernel-level,
   writer-non-overridable, filesystem-untouched, product-independent.
   Every evasion an agent invents is still a process in that tree —
   verified: a `setsid` group with an evasive write-loop child froze
   whole and resumed clean. `SIGCONT` only after adjudication (take the
   lane, or revert and release).
2. **Park** (corrected 2026-09-01; was "Revert") — the pre-freeze window's
   writes are diffed against the checkpoint and the root is parked for
   adjudication, loudly and durably. It does **not** promise automatic
   selective undo: where the lane owner and the violator touched the same
   file, the owner-only intermediate state is unrecoverable from `base` and
   `current` alone (see the retraction above), so an automatic revert would
   either destroy authorized work or retain the violation — both are silent
   resolutions the contract forbids. Restoring base remains available as an
   *explicit operator choice* with its cost stated, never as policy.
3. **Siren (optimization, not floor)** — where the product exposes a
   live-injection API, a message into the writer's own context ("you
   don't own this root; stop and establish provenance") catches the
   good-faith case before a freeze is needed. **Availability is
   asymmetric (spike 05): Codex's app-server accepts steer-into-live-turn
   today; Claude Code exposes no documented stable injection surface on
   either CLI or app.** So the reconciler must never depend on the siren
   — a Claude agent that cannot be sirened is simply frozen instead, and
   reads the situation from the sentinel when it resumes. If/when Claude
   Code ships an injection surface, the siren adapter lights up with no
   change to the floor.

Attribution feeding the ladder uses Endpoint Security (`audit_token`
carries the writer pid); it requires a one-time Full Disk Access grant to
the daemon (spike 05 — capability present, gated only by that GUI grant).

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

## Open shape question (2026-09-01) — unresolved, gates everything below

The owner's challenge, not yet answered: **is tier 1 the right shape at
all, or is it being defended by reaching for progressively harder
mechanisms?** Stated plainly so it is not lost:

- ES AUTH would answer the enforcement gap, but its entitlement is
  *discretionary Apple approval*, not a purchasable license. The brief for
  this work is a developer tool with specific grants — reaching for a
  harder gate to rescue a design is not a justification of that design.
- The original brief noted that relaxing **any** of (1) transparent
  original paths, (2) concurrent writes, (3) APFS-native reopens the design
  space, and that *which relaxation is cheapest was never explored*. Tier 1
  is the "relax concurrency" branch. The "relax transparency" branch —
  per-writer worktrees or separate checkouts, merged by git, with each
  writer confined by a Seatbelt profile it cannot loosen — has never been
  costed against it, despite needing no entitlement, no approval, no mount,
  and no new mechanism. Both branches satisfy the stated goal of preventing
  two agents from mutating one tree concurrently.
- Any answer that requires wiring a chokepoint into a specific agent
  harness is rejected on sight: that is the failure mode this project
  exists to address, and no such wiring will ever cover every edge case.

Until that comparison is done, tier 1 stands as *accident containment and
forensic review*, not as the converged enforcement design.

## Corrections to the evidence base (2026-09-01)

Verified defects found by re-reading the checked-in artifacts. Recorded
because each one weakens a claim the design was resting on:

- **Spike 05's `probe.sh` contains no freeze experiment at all** — zero
  occurrences of `SIGSTOP`/`kill -STOP`/`-CONT`. It runs only the eslogger
  attribution probe, which itself exits blocked on Full Disk Access. So
  "Freeze+revert: proven" rests on an observation with no reproducible
  artifact, while the one experiment that *is* committed did not pass.
- **`epochctl.py cmd_begin` unflags before it clones** —
  `set_flags(root, "nouchg")` precedes the `cp -cR` checkpoint, so guard
  mode's protection is dropped while the checkpoint does not yet exist. A
  write landing in that window is captured inconsistently and is not
  recoverable. Same failure shape as the ambient daemon's torn-clone gap.
- **The ambient "pre-burst base by construction" claim is unbuilt and
  unestablished** — there is no ambient daemon and no spike; FSEvents
  reports after the fact and cannot prevent a burst starting mid-clone.
- **Tier 1 does not satisfy CONTRACT.md** and needs its own weaker,
  separately named contract: guard mode makes the overlay visible to any
  unaware writer via `EPERM` with no divergence involved, which the
  contract permits only at a conflict.
- **Convention failed live, as predicted** — on 2026-09-01 a GUI-typed
  Codex turn ran to completion holding no lane, despite the acquire-it-
  yourself protocol being present in its own context. A writer that does
  not pass a chokepoint simply does not take the lane. This is evidence
  *for* mechanism over protocol, and against any harness-wiring fix.
