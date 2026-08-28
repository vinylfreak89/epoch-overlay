# The contract

This file states the observable semantics the overlay must provide. It leads
the design; DESIGN.md chooses mechanisms only insofar as they honor this.

## Strong case

1. **Completely transparent.** In the happy path, every process works at
   original absolute paths and cannot tell the overlay exists. No translated
   paths, no wrapper commands, no per-tool cooperation.
2. **No silent resolution — ever.** The overlay never auto-merges, never
   picks a winner, never drops a write. Divergence is either provably safe
   (three-way rule: `current == base`, or `current == result`) or it is a
   conflict.
3. **Conflicts are loud and self-describing.** A conflict is the one moment
   the overlay is allowed — required — to become visible. The failure must
   carry enough information that an agent which has never heard of the
   overlay can orient itself from the error alone:
   - that an overlay exists and interposed this work;
   - which branch the writer was working in, and since when;
   - the conflicting path(s), each with its base / result / current triple;
   - why this is a conflict (both sides changed the same base);
   - what the options are (rebase the branch, discard one side, escalate to
     the owner) and the exact command or handle for each.

   "Loud" means it cannot be missed by the audience it needs to reach: a
   human sees it in the surface they drive (Wheelhouse UI, terminal), and an
   agent mid-turn receives it in-band — a failing exit code with the full
   story on stderr when the boundary is a command, and a write error plus a
   self-describing sentinel (e.g. `<root>/.overlay/CONFLICT.md`) when the
   boundary is the filesystem itself, where errno alone is too narrow a
   channel to explain anything.

## Consequences for mechanism choice

- Transparency (1) is what forces original-path interposition; it is why
  this is an overlay and not a copy at a translated path.
- (2) means the merge engine is trivial by design — compare and apply or
  stop. All sophistication budget goes to (3), the error surface.
- (3) implies conflict state must be durable and inspectable, not just an
  event: a conflicted publication parks the branch (nothing is lost, nothing
  is applied beyond the provably-safe set) and leaves a machine- and
  human-readable record at a well-known location until resolved.
