# Spike 04 — uchg guard mode (kernel-enforced idle immutability)

Date: 2026-09-01. Machine: macOS 26.6.1, APFS, regular user. Driver:
`spike.sh` against `prototype/epochctl.py`; run printed
`ALL ASSERTIONS PASSED`.

## The mechanism (owner-identified)

A guarded root is `chflags uchg` on every entry while idle. Any writer —
agent or human, cooperative or oblivious — hits a kernel `EPERM` and, via
the `EPOCH-GUARDED.md` sentinel, learns exactly what to do:
`epochctl begin` (snapshot + unflag + lane) … work … `epochctl end`
(diff + re-flag). Enforcement is temporal, identical for everyone, and
needs no per-process attribution, no hooks, no overlay, no kext.

## Verified semantics (macOS 26.6.1)

- write / create / delete / rename against flagged entries → `EPERM`. ✓
- The flag is per-node, **not inherited**: an unflagged file inside a
  flagged directory is writable — so guard flags recursively and `end`
  re-flags to capture files created during the epoch (asserted). ✓
- Same-user `chflags nouchg` clears it: bypass requires a *deliberate*
  flag-clearing act, a meaningful step above ignoring an advisory lock. ✓
- Recursive flag flip on ~312 entries: **0.012 s**.
- Crash mid-epoch: root stays writable while `orphaned` (the epoch was
  legitimately open); `recover` re-flags. Sentinel deleted during an epoch
  is recreated at `end`. ✓

## iCloud policy (verified on this machine, enforced in code)

`uchg` on synced content breaks sync both ways: fileproviderd's sync-down
writes get the same `EPERM` as everyone else, and `uchg` is Finder's
"locked" bit, which iCloud propagates across devices. `guard` therefore
refuses any root inside a FileProvider domain (detected by walking
ancestors for the `com.apple.file-provider-domain-id` xattr) — asserted
against a real `~/Documents` path.

Machine finding that motivated the check: this Mac's `~/Documents` **is**
the CloudDocs Documents folder (same inode) with the domain in foreground
and actively syncing (`brctl status`: last-sync minutes ago, pending
sync-up items). Enforce-mode guarding of current project locations is
impossible; they get watch-only ambient coverage unless work areas move
outside iCloud scope.

## Consequence for the design

Guard mode gives tier 1 real mechanical protection for the *idle* state —
the common case. Tier 2's exclusive remaining value narrows to protection
*during* an open epoch (a rogue writer while someone legitimately holds
the root) plus true three-way publication. The covering-mount engine
becomes correspondingly less urgent.
