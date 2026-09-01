#!/bin/zsh
# Spike 04: uchg guard mode - kernel-enforced write refusal on idle guarded
# roots, epoch bracketing, crash recovery re-locking, iCloud-scope refusal.
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
for d in $(seq 1 10); do
  mkdir -p "$ROOT/mod$d"
  for f in $(seq 1 30); do echo "content $d/$f" > "$ROOT/mod$d/f$f.txt"; done
done

# --- guard: idle root refuses all writes ---------------------------------
python3 "$PY" guard --root "$ROOT" | tee "$S/guard.out"
grep -q "guarded" "$S/guard.out" || fail "guard did not confirm"
[ -f "$ROOT/EPOCH-GUARDED.md" ] || fail "sentinel missing"
(echo x >> "$ROOT/mod1/f1.txt") 2>/dev/null && fail "modify succeeded on guarded root"
(echo x > "$ROOT/newfile.txt") 2>/dev/null && fail "create succeeded on guarded root"
rm "$ROOT/mod2/f2.txt" 2>/dev/null && fail "delete succeeded on guarded root"
grep -q "epochctl begin" "$ROOT/EPOCH-GUARDED.md" || fail "sentinel not self-describing"

# --- begin: epoch unlocks; end: re-locks including new files -------------
sleep 600 >/dev/null 2>&1 & OWNER=$!; SLEEPERS+=($OWNER)
python3 "$PY" begin --root "$ROOT" --owner-pid $OWNER >/dev/null
echo changed >> "$ROOT/mod1/f1.txt" || fail "modify failed during epoch"
echo new > "$ROOT/created-in-epoch.txt" || fail "create failed during epoch"
rm "$ROOT/mod2/f2.txt" || fail "delete failed during epoch"
rm "$ROOT/EPOCH-GUARDED.md"   # epoch may even delete the sentinel
python3 "$PY" end --root "$ROOT" | tee "$S/end.out"
kill $OWNER 2>/dev/null || true
[ -f "$ROOT/EPOCH-GUARDED.md" ] || fail "sentinel not recreated at end"
(echo x >> "$ROOT/mod1/f1.txt") 2>/dev/null && fail "modify succeeded after re-lock"
(echo x >> "$ROOT/created-in-epoch.txt") 2>/dev/null && fail "file created in epoch not re-locked"

# --- crash mid-epoch: recover re-locks -----------------------------------
sleep 600 >/dev/null 2>&1 & OWNER2=$!; SLEEPERS+=($OWNER2)
python3 "$PY" begin --root "$ROOT" --owner-pid $OWNER2 >/dev/null
echo drift > "$ROOT/drift.txt"
kill -9 $OWNER2; wait $OWNER2 2>/dev/null || true
python3 "$PY" status | grep -q "ORPHANED" || fail "orphan not reported"
(echo x >> "$ROOT/drift.txt") || fail "root should still be writable while orphaned (epoch was open)"
python3 "$PY" recover --root "$ROOT" --action adopt >/dev/null
(echo x >> "$ROOT/drift.txt") 2>/dev/null && fail "recover did not re-lock guarded root"

# --- iCloud scope refusal -------------------------------------------------
ICTEST=~/Documents/.epoch-guard-icloud-test
mkdir -p "$ICTEST"
if EPOCH_STATE_DIR="$S/state" python3 "$PY" guard --root "$ICTEST" 2>"$S/ic.err"; then
  rmdir "$ICTEST"; fail "guard accepted an iCloud-scope root"
fi
grep -q "FileProvider" "$S/ic.err" || { rmdir "$ICTEST"; fail "iCloud refusal not explained"; }
rmdir "$ICTEST"

# --- unguard --------------------------------------------------------------
python3 "$PY" unguard --root "$ROOT" >/dev/null
(echo x >> "$ROOT/mod1/f1.txt") || fail "unguard did not restore writability"
[ ! -f "$ROOT/EPOCH-GUARDED.md" ] || fail "sentinel not removed by unguard"

echo "ALL ASSERTIONS PASSED"
