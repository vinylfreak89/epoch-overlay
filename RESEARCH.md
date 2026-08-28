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
  behavior is undocumented. Safe design: **enrolled roots and branch stores
  must live outside FileProvider-managed areas** in v1; results merge back
  into synced folders only as plain file writes.

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

- **AgentFS** (blocksense-network/agent-harbor): FSKit-based agent filesystem
  with snapshots, branches, lazy copy-up, and a claimed `bindProcess` XPC op
  binding a pid to a branch. Given Apple's no-attribution statement, the
  enforcement of that claim is suspect — read the source before trusting it.
- **loaf** (andrewgazelka/loaf): the same overlay-for-agents design, currently
  blocked on the 26.x fskitd bug; rejected `cp -c` clonefile as file-only.
- Codex CLI and Claude Code both sandbox via dynamically generated Seatbelt
  profiles (`sandbox-exec`, default-deny writes) — write-*deny* only, no
  redirect/CoW; complements an overlay, cannot replace it.
