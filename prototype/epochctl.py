#!/usr/bin/env python3
"""Tier-1 epoch lifecycle prototype (see DESIGN.md).

Per-root cooperative writer lane + APFS clonefile checkpoint + base->current
review. No TTLs: a dead owner orphans the lane; release is always an explicit
action.

Commands:
  begin   --root R [--owner-pid P]     acquire lane, clone base, activate
  end     --root R                     review (base->current), close, release
  status  [--root R]                   report lanes; detect orphans (no release)
  recover --root R --action adopt|abandon
                                       explicit resolution of an orphaned lane

State layout (one atomic lane dir per root under $EPOCH_STATE_DIR):
  <state>/<rootkey>/           lane dir; its existence IS the lane
      meta.json                root, epoch id, owner pid + start time, state
      base/                    clonefile checkpoint
      review.json              written at end / on orphan detection
  <state>/archive/<rootkey>-<epoch>/   closed lanes (kept as provenance)
"""
import argparse, ctypes, hashlib, json, os, subprocess, sys, time

_libc = ctypes.CDLL(None, use_errno=True)
_XATTR_NOFOLLOW = 0x0001


def _listxattr(path):
    """xattr names, not following symlinks (os.listxattr is Linux-only)."""
    b = path.encode()
    n = _libc.listxattr(b, None, 0, _XATTR_NOFOLLOW)
    if n <= 0:
        return []
    buf = ctypes.create_string_buffer(n)
    n = _libc.listxattr(b, buf, n, _XATTR_NOFOLLOW)
    if n <= 0:
        return []
    return [s.decode() for s in buf.raw[:n].split(b"\0") if s]


def _getxattr(path, name):
    b, nb = path.encode(), name.encode()
    n = _libc.getxattr(b, nb, None, 0, 0, _XATTR_NOFOLLOW)
    if n < 0:
        return b""
    buf = ctypes.create_string_buffer(n or 1)
    n = _libc.getxattr(b, nb, buf, n, 0, _XATTR_NOFOLLOW)
    return buf.raw[:max(n, 0)]

STATE = os.environ.get("EPOCH_STATE_DIR") or os.path.expanduser(
    "~/Library/Application Support/Wheelhouse/Epochs")


def die(msg, code=1):
    print(f"epochctl: {msg}", file=sys.stderr)
    sys.exit(code)


def rootkey(root):
    return hashlib.sha256(root.encode()).hexdigest()[:16]


def pid_start_time(pid):
    """kern.proc start time via ps; None if the pid is gone."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                             capture_output=True, text=True)
        s = out.stdout.strip()
        return s or None
    except OSError:
        return None


def scan_tree(top):
    """path -> descriptor for every entry under top (relative paths)."""
    entries = {}
    for dirpath, dirnames, filenames in os.walk(top):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, top)
            st = os.lstat(p)
            d = {"mode": st.st_mode}
            if os.path.islink(p):
                d["type"] = "symlink"
                d["target"] = os.readlink(p)
            elif os.path.isdir(p):
                d["type"] = "dir"
            else:
                d["type"] = "file"
                h = hashlib.blake2b(digest_size=16)
                with open(p, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                d["digest"] = h.hexdigest()
            xattrs = sorted(_listxattr(p))
            if xattrs:
                xh = hashlib.blake2b(digest_size=8)
                for a in xattrs:
                    xh.update(a.encode())
                    xh.update(_getxattr(p, a))
                d["xattrs"] = {"names": xattrs, "digest": xh.hexdigest()}
            entries[rel] = d
    return entries


def diff_trees(base, current):
    b, c = scan_tree(base), scan_tree(current)
    added = sorted(set(c) - set(b))
    deleted = sorted(set(b) - set(c))
    modified = sorted(p for p in set(b) & set(c) if b[p] != c[p])
    return {"added": added, "deleted": deleted, "modified": modified,
            "counts": {"base": len(b), "current": len(c),
                       "added": len(added), "deleted": len(deleted),
                       "modified": len(modified)}}


def lane_dir(root):
    return os.path.join(STATE, rootkey(root))


def read_meta(ld):
    with open(os.path.join(ld, "meta.json")) as f:
        return json.load(f)


def write_meta(ld, meta):
    tmp = os.path.join(ld, "meta.json.tmp")
    with open(tmp, "w") as f:
        json.dump(meta, f, indent=1)
    os.replace(tmp, os.path.join(ld, "meta.json"))


def resolve_root(path):
    root = os.path.realpath(path)
    if not os.path.isdir(root):
        die(f"root is not a directory: {root}")
    home = os.path.realpath(os.path.expanduser("~"))
    inside = root == home or root.startswith(home + os.sep)
    if not inside and not os.environ.get("EPOCH_ALLOW_ANY_ROOT"):
        die(f"root must be within {home} (set EPOCH_ALLOW_ANY_ROOT=1 to "
            "override for tests)")
    if os.path.realpath(STATE).startswith(root + os.sep):
        die("state dir may not live inside the enrolled root")
    return root


def cmd_begin(args):
    root = resolve_root(args.root)
    os.makedirs(STATE, exist_ok=True)
    ld = lane_dir(root)
    try:
        os.mkdir(ld)  # atomic acquisition; EEXIST == lane held
    except FileExistsError:
        meta = read_meta(ld)
        die(f"lane held for {root}: epoch {meta['epoch']} state "
            f"{meta['state']} owner pid {meta['owner_pid']} "
            f"(run status/recover; lanes are never stolen)", 75)
    pid = args.owner_pid or os.getppid()
    meta = {"root": root, "epoch": f"e{int(time.time())}-{os.getpid()}",
            "owner_pid": pid, "owner_start": pid_start_time(pid),
            "state": "opening", "opened_at": time.strftime("%FT%T%z")}
    write_meta(ld, meta)
    t0 = time.monotonic()
    r = subprocess.run(["cp", "-cR", root, os.path.join(ld, "base")],
                       capture_output=True, text=True)
    if r.returncode != 0:
        write_meta(ld, {**meta, "state": "failed", "error": r.stderr})
        die(f"base clone failed; lane parked in state 'failed': {r.stderr}")
    meta["state"] = "active"
    meta["clone_seconds"] = round(time.monotonic() - t0, 3)
    write_meta(ld, meta)
    print(f"epoch {meta['epoch']} active on {root} "
          f"(base cloned in {meta['clone_seconds']}s, owner pid {pid})")


def cmd_end(args):
    root = resolve_root(args.root)
    ld = lane_dir(root)
    if not os.path.isdir(ld):
        die(f"no lane for {root}")
    meta = read_meta(ld)
    if meta["state"] not in ("active", "reviewing"):
        die(f"lane state is {meta['state']}; use recover")
    meta["state"] = "reviewing"
    write_meta(ld, meta)
    review = diff_trees(os.path.join(ld, "base"), root)
    with open(os.path.join(ld, "review.json"), "w") as f:
        json.dump(review, f, indent=1)
    meta["state"] = "closed"
    meta["closed_at"] = time.strftime("%FT%T%z")
    write_meta(ld, meta)
    archive = os.path.join(STATE, "archive")
    os.makedirs(archive, exist_ok=True)
    os.rename(ld, os.path.join(archive, f"{rootkey(root)}-{meta['epoch']}"))
    print(json.dumps(review["counts"]))
    print(f"epoch {meta['epoch']} closed; lane released; checkpoint archived")


def cmd_status(args):
    if not os.path.isdir(STATE):
        print("no lanes")
        return
    lanes = [d for d in os.listdir(STATE)
             if d != "archive" and os.path.isdir(os.path.join(STATE, d))]
    if not lanes:
        print("no lanes")
    for d in lanes:
        ld = os.path.join(STATE, d)
        meta = read_meta(ld)
        live = (pid_start_time(meta["owner_pid"]) or "") == \
               (meta.get("owner_start") or "!")
        if meta["state"] == "active" and not live:
            meta["state"] = "orphaned"
            write_meta(ld, meta)
            review = diff_trees(os.path.join(ld, "base"), meta["root"])
            with open(os.path.join(ld, "review.json"), "w") as f:
                json.dump(review, f, indent=1)
            print(f"ORPHANED {meta['root']} epoch {meta['epoch']}: owner pid "
                  f"{meta['owner_pid']} is gone. Lane still held. Recovery "
                  f"diff: {ld}/review.json {json.dumps(review['counts'])}\n"
                  f"  resolve with: epochctl recover --root '{meta['root']}' "
                  f"--action adopt|abandon")
        else:
            print(f"{meta['state']:9s} {meta['root']} epoch {meta['epoch']} "
                  f"owner {meta['owner_pid']} ({'live' if live else 'gone'})")


def cmd_recover(args):
    root = resolve_root(args.root)
    ld = lane_dir(root)
    if not os.path.isdir(ld):
        die(f"no lane for {root}")
    meta = read_meta(ld)
    if meta["state"] not in ("orphaned", "failed"):
        die(f"lane state is {meta['state']}; recover applies to "
            "orphaned/failed lanes")
    # adopt: accept current canonical as the outcome (review stands as diff)
    # abandon: keep nothing but the archive; canonical stays as-is either way
    # -- tier 1 never rewrites canonical automatically (CONTRACT.md).
    meta["state"] = "closed"
    meta["resolution"] = args.action
    meta["closed_at"] = time.strftime("%FT%T%z")
    write_meta(ld, meta)
    archive = os.path.join(STATE, "archive")
    os.makedirs(archive, exist_ok=True)
    os.rename(ld, os.path.join(archive, f"{rootkey(root)}-{meta['epoch']}"))
    print(f"lane for {root} resolved ({args.action}); checkpoint archived")


def main():
    ap = argparse.ArgumentParser(prog="epochctl")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("begin", "end", "recover"):
        p = sub.add_parser(name)
        p.add_argument("--root", required=True)
        if name == "begin":
            p.add_argument("--owner-pid", type=int)
        if name == "recover":
            p.add_argument("--action", required=True,
                           choices=["adopt", "abandon"])
    sub.add_parser("status").add_argument("--root")
    args = ap.parse_args()
    {"begin": cmd_begin, "end": cmd_end,
     "status": cmd_status, "recover": cmd_recover}[args.cmd](args)


if __name__ == "__main__":
    main()
