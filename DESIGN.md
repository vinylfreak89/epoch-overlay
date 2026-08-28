# Epoch overlay — selective filesystem branches for coexisting agents

Status: **draft v0.1** — under active design exchange (Claude ⇄ Codex),
not yet converged. Spike evidence lives in `spikes/`.

## Problem

Two AI coding agents (and the human who drives both) share one macOS
filesystem as the same user. Either agent can mutate any path; advisory locks
cannot stop a writer that never learned the protocol. Prior investigation
established that a *fully transparent, per-process* overlay — two processes
seeing different content at one absolute path — is not achievable with public
native mechanisms: macOS has no mount namespaces, and (verified 2026-08-28)
FSKit volume operations receive **no caller identity** (no pid, no audit
token), so even a user-space filesystem cannot answer per-process.

The requirement has since been relaxed in one decisive way: transparency only
needs to cover **hand-picked roots** — a registry of folders that the user or
either agent enrolls — not the whole filesystem.

## Shape

If per-process views are impossible, stop trying to show two views at one
path. Make isolation **temporal instead of spatial**: a *write epoch* per
enrolled root.

```
        idle                     epoch(owner)                  publication
  ┌──────────────┐        ┌──────────────────────┐        ┌───────────────┐
  │ root = plain │ begin  │ overlay mounted AT   │  end   │ 3-way merge:  │
  │ APFS dir;    │───────▶│ the root; everyone   │───────▶│ base/result/  │
  │ iCloud syncs │        │ sees the branch view │        │ current       │
  └──────────────┘        │ at the original path │        └───────────────┘
                          └──────────────────────┘
```

### Epoch begin (a writer wants to mutate enrolled root X)

1. **Base snapshot**: APFS `clonefile` copy of X into the store (cheap CoW).
   This is `base` for the merge rule, plus provenance and undo.
2. **Branch**: create an empty `upper` directory in the store (a non-iCloud
   location).
3. **Mount**: an FSKit overlay module is mounted at X (`mount -F`). Before
   mounting, the module opens an fd on the real X; the mount shadows path
   lookup, but the fd keeps full access to the covered canonical directory
   (verified: `spikes/01-mount-shadow`). The module serves upper-over-lower
   with copy-up on write and whiteouts for deletes.

The epoch owner now works **fully transparently at original absolute paths**:
builds, embedded absolute paths, symlinks, tools that escape cwd — all see the
branch. Canonical is mechanically unreachable by path.

### Epoch end (publication)

Per path, the rule from the original brief, unchanged:

```
current == base                  apply the branch result
current == result                already equivalent
current != base and != base      conflict; never overwrite automatically
```

`current` can drift from `base` even during an epoch: a process holding a
pre-epoch fd bypasses the mount (verified in spike 01 — writes through such an
fd land in canonical). So publication always re-reads canonical; the three-way
rule is not collapsed to a blind apply. The `base` clone is retained as a
checkpoint after publication.

### Concurrency semantics

- **One epoch per root.** The writer lane is per enrolled root, not global —
  strictly finer than the global single-writer lane the prior brief
  recommended. Writers on different roots proceed concurrently.
- A second writer wanting an already-branched root either waits, asks the
  user, or takes an explicit isolated workspace (worktree / APFS clone at a
  translated path). Parallel mutation of one root is never inferred.
- During an epoch the *other* agent still reads the branch at the canonical
  path. That is deliberate: one reality, no divergent views. Readers see
  work-in-progress; that is what a shared checkout already means.

### Enforcement honesty

What is mechanical and what is advisory:

- **Mechanical**: canonical cannot be written *by path* during an epoch — the
  mount intercepts every lookup. Crash mid-epoch leaves canonical untouched
  and the branch salvageable in the store.
- **Advisory**: a non-owner writing during an epoch lands in the *branch*.
  Canonical is protected, but branch attribution is lost. The residual failure
  mode is contamination of a reviewable branch, not corruption of canonical —
  a strictly smaller blast radius than today.
- **Known bypass**: pre-epoch open fds reach canonical (spike 01). Mitigation:
  quiesce check (`lsof +D root`) at epoch begin, and the three-way rule at
  publication catches what slips through.

## iCloud

Canonical stays a plain APFS directory and syncs normally **while idle**.
During an epoch the root is shadowed and fileproviderd resolves paths through
the mount — behavior unverified. Open question whether v1 should refuse to
enroll iCloud-synced roots, pause sync for the epoch, or accept short epochs.
Branch stores always live outside iCloud scope.

## Candidate mechanisms, ranked by nativeness

1. **FSKit overlay module** (preferred). Verified on this machine: the macOS
   26 SDK ships `FSPathURLResource` / `FSGenericURLResource` (path-backed,
   non-block-device resources) and `mount -F` mounts FSModules. Open
   questions: end-to-end maturity of path-backed modules in shipping macOS;
   whether `mount -F` works without root; user-space FS throughput for build
   workloads.
2. **fuse-t** (middle option): kext-less FUSE via a localhost NFS server. No
   VM, no kext, but third-party.
3. **Thin Linux VM** (fallback): Virtualization.framework guest; lower layer
   shared into the guest via virtiofs, overlayfs upper inside the guest,
   merged view exported back to the host over NFS and mounted at the root.
   Same epoch/publication semantics — the VM is just the overlay engine.

## Open questions (tracked for convergence)

1. FSKit path-resource maturity and non-root `mount -F` — needs a spike with
   a minimal FSKit extension.
2. fileproviderd behavior when a synced folder is shadowed by a mount.
3. Quiesce policy at epoch begin (hard fail on open fds vs warn).
4. Epoch lifecycle binding: which agent-side events (Claude hook, Wheelhouse
   turn boundary) open and close an epoch; crashed-owner detection.
5. Branch attribution when a non-owner writes during an epoch.
6. Whether registry enrollment should be per-task (ephemeral) or persistent.
