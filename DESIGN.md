# Transparent overlay for coexisting agents — design space

Status: **draft v0.2** — under active design exchange (Claude ⇄ Codex), not
converged. Spike evidence in `spikes/`, web research in `RESEARCH.md`.

## Target (the owner's ideal, verbatim requirements)

1. **Fully transparent**: all file writes to the filesystem — or a large
   subsection of it, e.g. the home folder — go through the overlay. Agents
   work at original absolute paths without knowing the overlay exists.
2. **Concurrent writes**: an isolated writer (e.g. a dispatched Codex turn)
   mutates a private copy-on-write branch while other processes continue to
   see and mutate canonical content — at the same paths.
3. **macOS/APFS-native preferred.** A thin Linux VM serving an NFS-style
   overlay over *hand-picked folders* is the accepted fallback — the folder
   registry is a property of the fallback, not of the ideal.
4. **iCloud sync must keep working** throughout.

Publication happens at a boundary, per path, by the three-way rule:

```
current == base                 apply the branch result
current == result               already equivalent
current != base and result != base    conflict; never overwrite automatically
```

## Established facts (each verified — see RESEARCH.md and spikes/)

- **F1. FSKit has no per-operation caller identity.** Confirmed two ways:
  no pid/audit-token in any volume-operation signature in the macOS 26 SDK
  (local grep), and a direct Apple engineering statement to Meta's EdenFS
  team: "FSKit does not support process attribution." A single FSKit mount
  answers every process identically.
- **F2. Path-backed FSKit modules exist as of macOS 26.0**
  (`FSPathURLResource`), are mounted via non-root `mount -F`, but fskitd
  rejected unprivileged clients in 26.1/26.2 (Apple bugs); status on this
  machine's 26.6.1 unverified.
- **F3. Covering mounts work for regular users** over non-empty directories,
  and a pre-mount fd retains read/write access to covered content
  (spike 01).
- **F4. fileproviderd fights foreign mutation.** It has been observed
  reverting local shell operations inside synced areas; symlink and
  mountpoint tricks inside FileProvider-managed scope are hazardous and
  undocumented.
- **F5. macOS has no mount namespaces**; a mount is globally visible.
- **F6. Localhost userspace NFS servers mounted by the built-in client are a
  proven root-less pattern** (fuse-t, rclone nfsmount). NFS AUTH_SYS carries
  per-request uid/gid — but not pid.

## The central lemma

Requirements 1, 2 and 4 interlock:

> An overlay that interposes **all** writes in a scope must distinguish
> writers, or it cannot both capture an agent's writes into a branch and let
> fileproviderd's sync-down writes reach canonical. **No attribution ⇒ either
> the scope excludes iCloud-managed areas, or iCloud breaks by
> construction.**

With F1, every mac-native no-kext single-mount mechanism lacks attribution.
So the fully-transparent ideal survives only on routes that recover
attribution some other way:

| route | how attribution is recovered | cost |
|---|---|---|
| ~~macFUSE kext~~ | `fuse_context` carries pid per op | **eliminated — owner hard constraint**: no boot-security downgrade, no untrusted drivers on Apple Silicon. Kextless FUSE (fuse-t) survives as an API convenience only: its localhost-NFS and FSKit backends both lack per-op pid |
| second macOS user for the isolated agent + localhost NFS at original paths | AUTH_SYS uid per NFS RPC; server branches per uid | operational surgery: Codex runs as another user; permissions outside overlay scope |
| Endpoint Security client | ES auth events carry pid; can *deny* (gate) writes per process, not redirect them | restricted entitlement; root daemon; gives write-gating, not per-process content |
| agent in VM (Apple `container` / Virtualization.framework) | the VM boundary itself: guest recreates the same absolute paths (virtiofs lower + overlayfs upper); host untouched | it is the fallback, not the ideal; guest/host toolchain divergence |
| AgentFS-style `bindProcess` (claimed) | under source investigation — claim conflicts with F1 | unknown |

## Candidate shapes

### A. Fully transparent per-process overlay (the ideal)

Blocked native-and-kextless by F1 unless the AgentFS investigation or Apple
adds attribution. Nearest realizations, in descending nativeness: second-uid
NFS branch server; macFUSE; agent-in-VM. All three keep original absolute
paths for the isolated writer and true concurrency. iCloud survives by
exempting the fileproviderd-facing view (attribution makes that possible).

### B. Epoch overlay (temporal isolation — fallback shape, mac-native)

Documented at v0.1: mount an overlay *at* a root for the duration of a write
epoch; everyone sees the branch; canonical is mechanically unwritable by
path; publication = three-way rule; per-root writer lanes. Fails requirement
2 in the strict sense (same-root writers serialize; the concurrent writer's
changes land in the shared branch). Retained because it is native, kextless,
and mechanically protects canonical — but it is not the target.

### C. VM fallback (accepted by owner)

Thin Linux VM; hand-picked host folders shared as read-only lowers via
virtiofs; overlayfs upper on guest-local disk; merged view exported to the
host via NFS over host-only networking, or the agent simply runs inside the
guest at recreated absolute paths. Selective enrollment is inherent to this
shape (each folder needs a share + export). iCloud-safe by keeping enrolled
roots outside synced scope and merging back as plain writes.

## Open questions (convergence targets)

1. Does anything recover per-process attribution natively without a kext?
   (AgentFS source read pending; ES write-gating hybrid pending judgment.)
2. Is a whole-home overlay operationally survivable at all (login order,
   keychain, TCC, Spotlight, perf on hot paths), even given attribution —
   or is the realistic transparent scope "home minus system/iCloud areas"?
3. fskitd health on 26.6.1 (spike needed: minimal path-backed module).
4. Second-user route: can Codex run usably as another uid with the NFS
   overlay granting it access *within* scope? What breaks outside scope?
5. VM route: virtiofs xattr support for overlayfs upper on this host;
   guest→host NFS perf for builds.
6. Publication UX: epoch boundaries, conflict surfacing, provenance.
