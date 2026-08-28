# epoch-overlay

Design and prototypes for letting multiple coding agents (Claude Code,
Codex, and the human driving both) safely mutate one shared macOS
filesystem — without kexts, without boot-security downgrades, without
moving agents into VMs, and without breaking iCloud sync.

**Read in this order:**

1. [`CONTRACT.md`](CONTRACT.md) — the observable semantics: transparent
   until conflict; no silent resolution; conflicts loud, parked, and
   self-describing.
2. [`DESIGN.md`](DESIGN.md) — the converged two-tier epoch design
   (v1.0, Claude ⇄ Codex design exchange).
3. [`RESEARCH.md`](RESEARCH.md) — verified platform facts: FSKit has no
   per-operation process attribution (Apple statement + SDK inspection),
   path-backed FSKit is macOS 26.0+, fileproviderd behavior, prior art
   (AgentFS, loaf), VM-engine specifics.
4. [`spikes/`](spikes/) — empirical evidence; each spike has a script and
   a RESULTS.md with verdicts.

In one paragraph: per-root **write epochs** instead of per-process views
(which macOS cannot provide without eliminated mechanisms). Tier 1 —
buildable today — is a per-root writer lane, an APFS `clonefile` checkpoint
as `base`, in-place native writes at original paths, and a durable
`base → current` review with no-TTL orphan recovery. Tier 2 adds a covering
mount during epochs (FSKit / fuse-t / thin VM as filesystem engine only),
which mechanically protects canonical and upgrades review into true
three-way publication with loud parked conflicts.
