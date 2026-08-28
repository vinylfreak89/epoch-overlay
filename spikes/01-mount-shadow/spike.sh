#!/bin/zsh
# Spike: can a user-level mount shadow a NON-EMPTY directory, and does a
# pre-opened fd still reach the covered (canonical) content?
set -x
S=/private/tmp/claude-501/-Users-vinylfreak89-Documents-agent-coordination/abf314ae-0e8c-4aa4-b569-8e074e233264/scratchpad/mntspike
rm -rf "$S"; mkdir -p "$S/target"
echo canonical-content > "$S/target/canary.txt"

# holder: opens an fd on target BEFORE the mount, then reads through it after
python3 - "$S" <<'EOF' &
import os, sys, time, json
s = sys.argv[1]
fd = os.open(f"{s}/target", os.O_RDONLY)
# wait for the mount marker
while not os.path.exists(f"{s}/mounted"):
    time.sleep(0.2)
time.sleep(0.5)
out = {}
out["listdir_via_fd"] = os.listdir(fd)
try:
    cfd = os.open("canary.txt", os.O_RDONLY, dir_fd=fd)
    out["canary_via_fd"] = os.read(cfd, 100).decode().strip()
    os.close(cfd)
except OSError as e:
    out["canary_via_fd"] = f"ERR {e}"
out["listdir_via_path"] = os.listdir(f"{s}/target")
# try WRITING canonical through the fd while covered
try:
    wfd = os.open("written-under-mount.txt", os.O_CREAT|os.O_WRONLY, 0o644, dir_fd=fd)
    os.write(wfd, b"bypass\n"); os.close(wfd)
    out["write_via_fd"] = "ok"
except OSError as e:
    out["write_via_fd"] = f"ERR {e}"
with open(f"{s}/holder-result.json","w") as f:
    json.dump(out, f, indent=1)
EOF
HOLDER=$!

hdiutil create -size 5m -fs APFS -volname SPIKE "$S/spike.dmg" -quiet || exit 1
# mount OVER the non-empty directory, as a regular user, nobrowse
hdiutil attach "$S/spike.dmg" -mountpoint "$S/target" -nobrowse -quiet
echo "attach_status=$?"
touch "$S/mounted"
echo overlay-content > "$S/target/overlay.txt" 2>/dev/null && echo "wrote overlay.txt into mount"
ls -la "$S/target/"
wait $HOLDER
hdiutil detach "$S/target" -quiet
echo "=== after detach, canonical dir: ==="
ls -la "$S/target/"
echo "=== holder result ==="
cat "$S/holder-result.json"
