# Spike 01 — mount-shadow mechanics

Date: 2026-08-28. Machine: macOS 26.6.1 (25G76), APFS, regular user (no root).

## Question

Four mechanics the epoch-overlay design depends on:

1. Can a regular user mount a filesystem *over a non-empty directory*?
2. Does the mount shadow path lookup for every process?
3. Does a process that opened an fd on the directory *before* the mount still
   reach the covered (canonical) content through that fd (`openat`/`dir_fd`)?
4. Can such an fd holder *write* the canonical directory while it is covered?

## Method

`spike.sh`: create `target/` containing `canary.txt`; a Python holder opens
`O_RDONLY` fd on `target/` and waits; `hdiutil create` a 5 MB APFS image and
`hdiutil attach -mountpoint target/ -nobrowse`; holder then lists/reads/writes
via `dir_fd` while the shell lists via path; detach and inspect.

## Results (verbatim holder output)

```json
{
 "listdir_via_fd": ["canary.txt"],
 "canary_via_fd": "canonical-content",
 "listdir_via_path": ["overlay.txt"],
 "write_via_fd": "ok"
}
```

- `hdiutil attach` over the non-empty directory returned status 0, as a
  regular user. After detach, canonical content was intact, plus the file the
  holder wrote through its fd while covered.

## Verdicts

1. **Yes** — user-level mount over a non-empty directory works (via
   DiskArbitration; whether `mount -F`/FSKit mounts get the same treatment is
   a separate open question).
2. **Yes** — path lookup resolved to the mounted volume (`overlay.txt`), the
   canonical `canary.txt` invisible by path.
3. **Yes** — the pre-opened fd kept full access to covered content. An overlay
   daemon can therefore serve its lower layer through an fd opened before
   mounting over the root.
4. **Yes** — writes through a pre-existing fd land in covered canonical. Two
   consequences: (a) the publication step can *apply* the branch to canonical
   through the daemon's fd even before unmounting; (b) the open-fd bypass is
   real — a process holding a pre-epoch fd can mutate canonical while it is
   shadowed, so publication must keep the full three-way rule
   (`current == base?`) rather than assuming canonical could not drift.
