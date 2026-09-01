# Research notes — mechanism feasibility (2026-08-28)

Web research summary backing the design; local verifications live in
`spikes/`. Confidence marked per item.

## FSKit path-backed filesystems

- `FSPathURLResource` / `FSGenericURLResource` were **introduced in macOS
  26.0** (docs metadata `introducedAt: "26.0"`); macOS 15.x FSKit was
  block-device-only in practice. Path-backed modules are mounted with
  `/sbin/mount -F -t <fstype>` — per Apple DTS, `mount` is the intended
  interface for non-block resources (DiskArbitration is block-only).
  [developer.apple.com/forums/thread/799283]
- **Non-root `mount -F` is the normal path** for user-accessible resources;
  `sudo mount -F` is actually *more* broken because FSKit extension
  enablement is per-user. [developer.apple.com/forums/thread/788609]
- **Known instability:** third-party FSKit extensions reported broken on
  macOS 26.1/26.2 (`fskitd` rejecting unprivileged clients, FB18230524,
  FB17772372) — yet fuse-t ≥ 1.1.0 ships a native FSKit backend for 26+.
  Contradiction unresolved; **must be spike-tested on this machine (26.6.1)**.
  [github.com/andrewgazelka/loaf/issues/1, github.com/macos-fuse-t/fuse-t]
- Perf caveat: reports of FSKit user-space I/O costing 100–150% CPU vs ~40%
  for equivalent macFUSE; the kernel-offloaded fast path
  (`FSVolumeKernelOffloadedIOOperations`) requires a real block device, so a
  virtual overlay cannot use it. Confidence: medium.

## Per-process views: verified dead

Apple systems engineering, responding to Meta's EdenFS team asking for
FUSE-style per-request pid (Feb 2025): *"FSKit does not support process
attribution. xnu fundamentally gates initial file access on user or group."*
Audit tokens appear only at resource-open/mount time. This matches the local
SDK grep (no pid/audit token in any volume-operation signature). The
brief's open question — whether a user-space FS could answer per-caller — is
now **verified negative** for FSKit as shipped. Isolation must be temporal
(this design) or spatial-at-different-paths, or a VM.
[developer.apple.com/forums/thread/766793] Confidence: high.

## Mount mechanics

- Mounting over a non-empty directory is allowed; contents are covered until
  unmount. `-o union` is broken since Sierra; do not use.
- Covered-dir fd access: **verified locally** (spike 01) — a pre-mount fd
  retains read and write access to the covered directory.
- Non-root NFS-localhost mounts are a proven pattern: fuse-t and rclone
  `nfsmount` both spawn a userspace NFS server on loopback and have the
  built-in macOS NFS client mount it, no root, no kext.

## iCloud / fileproviderd

- fileproviderd has been observed **silently reverting** local shell
  mutations (mv/rm/git mv) inside synced areas, reconciling back to cloud
  state. [github.com/anthropics/claude-code/issues/47241]
- Symlinks in iCloud areas don't sync usefully; mountpoint-inside-synced-area
  behavior is undocumented. Safe design: ~~**enrolled roots and branch stores
  must live outside FileProvider-managed areas** in v1~~ — **superseded
  2026-09-01, see below**; branch stores are still never placed in synced
  areas.

### CloudDocs: the v1 rule above is overturned (2026-09-01)

Recording this because the decision was made in spike 04 and never written
back here, leaving the two documents in contradiction.

`~/Documents` on this machine **is** the CloudDocs Documents folder (same
inode), domain in foreground, actively syncing. So "enrolled roots must live
outside FileProvider-managed areas" would exclude the actual work. The owner's
position is explicit: **files are synced with iCloud loudly on purpose, and the
work is not moving out of `~/Documents`.**

What that costs, per mechanism:

- **`uchg` guard mode is unusable there, permanently.** fileproviderd's
  sync-down writes take the same `EPERM` as everyone else, and `uchg` is
  Finder's "locked" bit, which iCloud propagates across devices. `epochctl
  guard` refuses FileProvider roots unconditionally, and that refusal is
  correct, not a limitation to engineer around.
- **Attribution-based mechanisms are compatible**, and uniquely so: ES
  carries the writer's `audit_token`, so fileproviderd/bird can be allowed at
  the same path where an unowned agent is denied. This is exactly why the
  bypass allowlist is possible, and it is the strongest argument for the ES
  direction over flag-based enforcement.

**Relocation via symlink was considered and rejected.** A symlink cannot yield
"synced but not FileProvider-managed": either the content resolves into the
CloudDocs domain, and dataless materialization plus fileproviderd's writes
follow it, or it lives outside and is not synced at all — which defeats the
purpose. Combined with the note above that symlinks in iCloud areas don't sync
usefully, this route is closed. Attribution, not relocation, is the answer.

## Endpoint Security — pre-operation gates (SDK-verified 2026-09-01)

Verified by inspecting this machine's SDKs, the same method used to settle
FSKit's lack of attribution:

- **44 `ES_EVENT_TYPE_AUTH_*` events** in the MacOSX26 SDK, including
  `AUTH_OPEN`, `AUTH_CREATE`, `AUTH_TRUNCATE`, `AUTH_RENAME`, `AUTH_UNLINK`,
  `AUTH_CLONE`, `AUTH_LINK`, `AUTH_COPYFILE`, `AUTH_EXCHANGEDATA`,
  `AUTH_SETATTRLIST`, `AUTH_SETMODE`, `AUTH_MMAP`. AUTH events are
  synchronous: the kernel suspends the caller until the client answers.
- **No `ES_EVENT_TYPE_AUTH_WRITE`** — absent in both the 14.4 and 26.x SDKs.
  Individual `write(2)` calls are not authorizable; the gate is the
  open/create/rename/unlink/truncate/mmap boundary. An fd opened before the
  policy applies still writes through, the same bypass spike 01 found for
  covering mounts.
- **`deadline`** is a documented per-message field: "the Mach absolute time
  before which an auth event must be responded to", and clients that miss it
  are killed. Policy must therefore decide in milliseconds. Confidence: high
  (read from the shipped headers).
- **Entitlement**: `com.apple.developer.endpoint-security.client` is
  restricted and requires Apple's discretionary approval, which is a
  different and harder gate than FSKit's paid-program requirement. Apple's
  own `eslogger` is NOTIFY-only, so AUTH cannot be exercised through it.
  **Unverified**: whether that approval is obtainable here. This is the open
  risk, and it is the reason the shape question in DESIGN.md is unresolved
  rather than settled in ES's favour.
- **Seatbelt is the no-approval alternative worth costing**: Claude Code and
  Codex already confine themselves with generated `sandbox-exec` profiles
  (default-deny writes) at original paths, needing no entitlement and no
  root. Sandbox policies are inherited by children and can only be tightened,
  never loosened, so a confined agent cannot escape by spawning a helper —
  which is precisely the containment property SIGSTOP-on-a-process-group was
  claimed to have and does not. Its limit is that it binds at launch, so it
  covers writers we start and not arbitrary ones.

## VM fallback specifics

- overlayfs upperdir on virtiofs is supported since Linux 5.7 but requires
  xattr/d_type/tmpfile support on the share — mixed reports; the robust shape
  is lowerdir = virtiofs (read-only host view), upperdir/workdir =
  guest-local ext4. That also keeps writes off the host until publication,
  matching the epoch model.
- Guest→host export channel: NFS over Virtualization.framework host-only
  networking, mounted by the built-in macOS NFS client. NFS-over-vsock is not
  available on the macOS client side.
- Apple's open-source `container` tool (macOS 26, Containerization framework,
  one lightweight VM per container, virtiofs shares, sub-second boot) is a
  ready-made engine for this fallback. [github.com/apple/container]

## Prior art

- **AgentFS** (blocksense-network/agent-harbor) — source-verified 2026-08-29
  (repo since gone private; read via DeepWiki index of commit `edcda2bd` plus
  their live docs). Verdict: **cooperative only, no attribution trick.**
  `bindProcess` inserts a *client-supplied* pid into a `HashMap<pid,BranchId>`
  in FsCore; it is honored per-operation only where the platform supplies a
  caller pid — their Linux FUSE adapter. The macOS FSKit adapter's FFI
  surface (`agentfs_open(ctx, path, mode)` …) carries no pid or audit token
  anywhere. Their DYLD-interpose variant self-reports identity over a socket
  handshake (no peer-credential check). Apple's no-attribution statement is
  corroborated, not refuted.
  What their shipped macOS design *does* reveal: **path-encoded attribution**
  — one mount exposes each branch as a distinct full-root directory
  (`/branches/task-N/...`, "path-based resolution, no kernel PID lookup"),
  and each agent is confined into its branch (their docs say chroot;
  their launcher code applies a Seatbelt profile via `sandbox_init`).
  Steal-worthy ideas: CloneEager branch materialization (APFS `clonefile`
  per file — O(n) metadata, minimal storage, strong isolation), copy-up via
  `clone_cow`/clonefile, whiteouts, metadata-only overlay entries, and
  SCM_RIGHTS fd-forwarding so data I/O runs at native speed while only
  namespace operations are brokered. Their FSKit mount has no CI test on any
  macOS (filesystem tests run only on Linux/FUSE) — treat the module itself
  as unproven.
- **loaf** (andrewgazelka/loaf): the same overlay-for-agents design, currently
  blocked on the 26.x fskitd bug; rejected `cp -c` clonefile as file-only.
- Codex CLI and Claude Code both sandbox via dynamically generated Seatbelt
  profiles (`sandbox-exec`, default-deny writes) — write-*deny* only, no
  redirect/CoW; complements an overlay, cannot replace it.
