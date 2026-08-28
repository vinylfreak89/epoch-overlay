#!/bin/zsh
# Spike 02: tier-1 epoch lifecycle end-to-end (see DESIGN.md "Next spike").
# Exercises: atomic lane, clonefile checkpoint timing, full mutation matrix,
# base->current review counts, lane contention, kill-owner orphan handling,
# explicit recovery. Hard-asserts every claim.
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
S="${SPIKE_SCRATCH:?set SPIKE_SCRATCH to a scratch dir}"
export EPOCH_STATE_DIR="$S/state"
export EPOCH_ALLOW_ANY_ROOT=1
PY="$REPO/prototype/epochctl.py"
SLEEPERS=()
trap '[ ${#SLEEPERS[@]} -gt 0 ] && kill $SLEEPERS 2>/dev/null' EXIT
ROOT="$S/worktree"
fail() { echo "SPIKE FAILED: $1"; exit 1; }

rm -rf "$S"; mkdir -p "$ROOT"
# synthetic tree: 1500 small files in 30 dirs, one 50MB binary, symlink, xattr
for d in $(seq 1 30); do
  mkdir -p "$ROOT/mod$d/sub"
  for f in $(seq 1 50); do echo "content $d/$f" > "$ROOT/mod$d/sub/f$f.txt"; done
done
mkfile -n 50m "$ROOT/blob.bin" 2>/dev/null || dd if=/dev/zero of="$ROOT/blob.bin" bs=1m count=50 status=none
ln -s mod1/sub/f1.txt "$ROOT/link"
xattr -w com.example.tag original "$ROOT/mod2/sub/f2.txt"
echo "tree: $(find "$ROOT" | wc -l | tr -d ' ') entries, $(du -sh "$ROOT" | cut -f1)"

# --- epoch 1: normal lifecycle -------------------------------------------
sleep 600 >/dev/null 2>&1 & OWNER=$!; SLEEPERS+=($OWNER)
python3 "$PY" begin --root "$ROOT" --owner-pid $OWNER | tee "$S/begin1.out"
grep -q "active" "$S/begin1.out" || fail "epoch 1 did not activate"
echo "base store usage: apparent $(du -sh "$EPOCH_STATE_DIR" | cut -f1), actual $(du -sh -A "$EPOCH_STATE_DIR" 2>/dev/null | cut -f1 || echo n/a)"
df_after=$(df -k "$S" | tail -1 | awk '{print $4}')

# contention: second begin on same root must fail with lane-held
if python3 "$PY" begin --root "$ROOT" --owner-pid $$ 2>"$S/contend.err"; then
  fail "second begin on held lane succeeded"
fi
grep -q "lane held" "$S/contend.err" || fail "contention error not loud/named"

# mutation matrix at ORIGINAL paths
echo changed >> "$ROOT/mod1/sub/f1.txt"          # modify content
echo new > "$ROOT/mod1/sub/created.txt"          # create
rm "$ROOT/mod3/sub/f3.txt"                       # delete
mv "$ROOT/mod4/sub/f4.txt" "$ROOT/mod4/sub/renamed.txt"  # rename (=del+add)
ln -sfh mod2/sub/f2.txt "$ROOT/link"             # symlink retarget
xattr -w com.example.tag mutated "$ROOT/mod2/sub/f2.txt"  # xattr change
chmod 600 "$ROOT/mod5/sub/f5.txt"                # mode change

python3 "$PY" end --root "$ROOT" | tee "$S/end1.out"
kill $OWNER 2>/dev/null || true
counts=$(head -1 "$S/end1.out")
echo "review counts: $counts"
# expected: added 2 (created.txt, renamed.txt), deleted 2 (f3, f4),
# modified 4 (f1 content, link target, f2 xattr, f5 mode)
[ "$(echo "$counts" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c["added"], c["deleted"], c["modified"])')" = "2 2 4" ] \
  || fail "review counts wrong: $counts"

# --- epoch 2: kill owner mid-epoch ---------------------------------------
sleep 600 >/dev/null 2>&1 & OWNER2=$!; SLEEPERS+=($OWNER2)
python3 "$PY" begin --root "$ROOT" --owner-pid $OWNER2 >/dev/null
echo drift > "$ROOT/mod6/sub/drift.txt"          # mutation before the crash
kill -9 $OWNER2; wait $OWNER2 2>/dev/null || true
python3 "$PY" status | tee "$S/status2.out"
grep -q "ORPHANED" "$S/status2.out" || fail "dead owner not reported orphaned"
grep -q "Lane still held" "$S/status2.out" || fail "orphan message incomplete"
# lane must still be held: begin must refuse
if python3 "$PY" begin --root "$ROOT" --owner-pid $$ 2>"$S/contend2.err"; then
  fail "orphaned lane was silently stealable"
fi
# recovery diff must exist and show the drift
ls "$EPOCH_STATE_DIR"/*/review.json >/dev/null || fail "no recovery diff written"
grep -q "drift.txt" "$EPOCH_STATE_DIR"/*/review.json || fail "recovery diff missed the mid-epoch write"
# explicit recovery releases; a new epoch can then begin
python3 "$PY" recover --root "$ROOT" --action adopt | grep -q resolved || fail "recover failed"
sleep 600 >/dev/null 2>&1 & OWNER3=$!; SLEEPERS+=($OWNER3)
python3 "$PY" begin --root "$ROOT" --owner-pid $OWNER3 >/dev/null || fail "begin after recovery failed"
python3 "$PY" end --root "$ROOT" >/dev/null
kill $OWNER3 2>/dev/null || true

echo "ALL ASSERTIONS PASSED"
