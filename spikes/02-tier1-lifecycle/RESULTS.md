# Spike 02 — tier-1 epoch lifecycle end-to-end

Date: 2026-08-29. Machine: macOS 26.6.1, APFS, regular user.
Driver: `spike.sh` against `prototype/epochctl.py`. Every claim below is a
hard assertion in the script; the run printed `ALL ASSERTIONS PASSED`.

## Setup

Synthetic root: 1563 entries (30 dirs × 50 small files, one 50 MB
`mkfile -n` blob, a symlink, one xattr-tagged file).

## Results

| claim | result |
|---|---|
| atomic lane acquisition (mkdir) | ✓; second `begin` on a held lane exits 75 with a named, loud error |
| base checkpoint via `cp -cR` (clonefile) | ✓ — **0.192 s** for 1563 entries |
| in-place mutation at original paths | ✓ — modify, create, delete, rename, symlink retarget, xattr change, chmod |
| `base → current` review exactness | ✓ — counts {added 2, deleted 2, modified 4} match prediction; xattr and mode changes detected via libc `listxattr`/`getxattr` (ctypes — `os.listxattr` does not exist on macOS Python) |
| kill -9 owner mid-epoch | ✓ — `status` reports `ORPHANED`, states the lane is still held, writes a recovery diff that includes the mid-epoch write (`drift.txt`) |
| no lane stealing | ✓ — `begin` refuses on the orphaned lane |
| explicit recovery only | ✓ — `recover --action adopt` releases; the next epoch then begins normally |
| owner liveness check | pid + `ps lstart` process-start-time match, so pid reuse cannot masquerade as a live owner |

## Caveats / notes

- Clone-time disk metrics were inconclusive in this run because the 50 MB
  blob was created sparse (`mkfile -n`); `du` also cannot see APFS extent
  sharing. Clone *time* (0.19 s) is the meaningful number here; extent
  sharing itself is standard clonefile behavior.
- The review scanner hashes every file on both sides (O(tree) per epoch
  end). Fine at this scale; a real implementation should short-circuit on
  (size, mtime) equality before hashing.
- Consistent with DESIGN.md's honesty note: the recursive clone is not
  atomic, and a lane-violating writer's changes would be indistinguishable
  in the diff — nothing in this spike contradicts the tier-1 limits.
