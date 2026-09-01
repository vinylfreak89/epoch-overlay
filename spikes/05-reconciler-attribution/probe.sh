#!/bin/zsh
# Spike 05: per-operation write attribution via Apple's eslogger (runs as
# root through sudo_run). Captures ES file events while a known child pid
# writes a probe file, then verifies the event carries that pid.
set -e
OUT="${1:?usage: probe.sh <output-dir>}"
mkdir -p "$OUT"

/usr/bin/eslogger --format json create write rename unlink \
  > "$OUT/es.jsonl" 2> "$OUT/es.err" &
ES=$!
sleep 2

/usr/bin/python3 - "$OUT" <<'EOF'
import os, sys
out = sys.argv[1]
with open(os.path.join(out, "writer-pid.txt"), "w") as f:
    f.write(str(os.getpid()))
with open(os.path.join(out, "probe-target.txt"), "w") as f:
    f.write("attribution probe\n")
EOF

sleep 3
kill $ES 2>/dev/null || true
wait $ES 2>/dev/null || true

/usr/bin/python3 - "$OUT" <<'EOF'
import json, os, sys
out = sys.argv[1]
writer = open(os.path.join(out, "writer-pid.txt")).read().strip()
hits = []
for line in open(os.path.join(out, "es.jsonl")):
    if "probe-target.txt" in line:
        try:
            hits.append(json.loads(line))
        except ValueError:
            pass
if not hits:
    print("VERDICT: FAIL - no ES events captured for the probe file "
          f"(es.err: {open(os.path.join(out,'es.jsonl')).read()[:0]}"
          f"{open(os.path.join(out,'es.err')).read()[:300]})")
    sys.exit(1)
pids = set()
for h in hits:
    p = h.get("process", {})
    pid = p.get("audit_token", {}).get("pid") or p.get("pid")
    pids.add(str(pid))
print(f"captured {len(hits)} events for the probe file; "
      f"writer pid {writer}; event pids {sorted(pids)}")
if writer in pids:
    print("VERDICT: PASS - per-op pid attribution confirmed via eslogger")
else:
    print("VERDICT: PARTIAL - events captured but pid field mismatch; "
          "inspect es.jsonl schema")
EOF
