#!/usr/bin/env bash
# Tests for Tools/build_city.sh and Tools/build_chicago.sh: argument handling and the preflight.
# Nothing is downloaded or built. Every case uses --check-only with fake memory and disk values
# (GULLFIRE_FAKE_RAM_GB, GULLFIRE_FAKE_FREE_GB).
#
#   Tools/test_build_city.sh     exit 0 when every check passes, 1 otherwise
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Tools/build_city.sh"
CHICAGO="$ROOT/Tools/build_chicago.sh"
RECIPES="$ROOT/Resources/Recipes/recipes.json"
PASS=0
FAIL=0

# run NAME WANT_EXIT RAM FREE PATTERN1 PATTERN2 ARGS...
# PATTERN1 and PATTERN2 are extended regular expressions the output must match; "" means none.
# TARGET selects the script (default: build_city.sh).
run() {
    local name="$1" want="$2" ram="$3" free="$4" pat1="$5" pat2="$6"
    shift 6
    local target="${TARGET:-$SCRIPT}"
    local out rc ok=1
    out="$(GULLFIRE_FAKE_RAM_GB="$ram" GULLFIRE_FAKE_FREE_GB="$free" bash "$target" "$@" 2>&1)"
    rc=$?
    [ "$rc" -eq "$want" ] || ok=0
    if [ -n "$pat1" ] && ! printf '%s\n' "$out" | grep -Eq -- "$pat1"; then ok=0; fi
    if [ -n "$pat2" ] && ! printf '%s\n' "$out" | grep -Eq -- "$pat2"; then ok=0; fi
    if [ "$ok" -eq 1 ]; then
        PASS=$((PASS + 1))
        echo "ok    $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL  $name (exit $rc, wanted $want)"
        printf '%s\n' "$out" | sed 's/^/      | /'
    fi
}

# a) an unknown id exits 2 and lists the valid ids
run "unknown id exits 2 and lists the ids" 2 8 100 "valid ids:.*chicago" "" nosuchmap --check-only

# b) Chicago on an 8 GB Mac with 100 GB free passes
run "chicago, 8 GB and 100 GB free: passes" 0 8 100 "Check only" "" chicago --check-only

# c) Cook County on an 8 GB Mac is refused for memory, and nothing is downloaded
run "cookcounty, 8 GB: refused for memory" 3 8 100 "memory +[0-9.]+ GB : too low" "Nothing was downloaded" cookcounty --check-only

# d) Cook County with 48 GB of memory but 5 GB free is refused for disk
run "cookcounty, 48 GB and 5 GB free: refused for disk" 3 48 5 "free disk .*: too low" "Nothing was downloaded" cookcounty --check-only

# e) the same small Mac with --force passes the check, with a warning
run "cookcounty, 8 GB, --force --check-only: exits 0 with a warning" 0 8 100 "WARNING" "Check only" cookcounty --force --check-only

# f) every id in recipes.json is accepted by the id check
IDS="$(python3 -I -c 'import json, sys; print(" ".join(r["id"] for r in json.load(open(sys.argv[1]))["recipes"]))' "$RECIPES")"
if [ -z "$IDS" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL  recipes.json lists no ids"
fi
for id in $IDS; do
    run "recipe id '$id' is accepted" 0 48 100 "Check only" "" "$id" --check-only
done

# g) syntax of both scripts
for f in "$CHICAGO" "$SCRIPT"; do
    if bash -n "$f"; then
        PASS=$((PASS + 1)); echo "ok    bash -n $(basename "$f")"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  bash -n $(basename "$f")"
    fi
done

# h) build_chicago.sh hands over to build_city.sh with the same options
TARGET="$CHICAGO" run "build_chicago.sh --check-only on 8 GB: passes" 0 8 100 "Check only" "" --check-only
TARGET="$CHICAGO" run "build_chicago.sh --check-only on 4 GB: refused" 3 4 100 "memory +[0-9.]+ GB : too low" "Nothing was downloaded" --check-only
TARGET="$CHICAGO" run "build_chicago.sh --dest with --check-only: passes" 0 8 100 "Check only" "" --dest /nonexistent/xyz --check-only

# i) --build-dir: the preflight names the folder it will build in; a missing value exits 2
BD="$(mktemp -d)"
run "--build-dir names the build folder" 0 8 100 "folder $BD" "Check only" chicago --build-dir "$BD" --check-only
run "--build-dir without a value exits 2" 2 8 100 "needs a folder" "" chicago --build-dir
rm -rf "$BD"

# j) --overture-release: a missing value exits 2; a release that is no longer published stops fetch_city.py
#    before it downloads anything, and says what --overture-release latest means (a fake catalogue, no network)
run "--overture-release without a value exits 2" 2 8 100 "needs latest or a release id" "" chicago --overture-release
FD="$(mktemp -d)"
OUT="$(GULLFIRE_OVERTURE_RELEASES="2026-09-23.0,2026-11-18.0" uv run --quiet --with numpy --with shapely Tools/fetch_city.py chicago --out "$FD" 2>&1)"; CODE=$?
if [ "$CODE" -eq 1 ] && echo "$OUT" | grep -q "2026-10-21.0 is no longer published" && echo "$OUT" | grep -q "Nothing was downloaded" \
   && echo "$OUT" | grep -q "latest builds from the newest release" && [ -z "$(find "$FD" -name '*.geojsonl' 2>/dev/null)" ]; then
    echo "ok   a release that is gone stops before downloading"; PASS=$((PASS+1))
else
    echo "FAIL a release that is gone stops before downloading (exit $CODE)"; echo "$OUT" | sed 's/^/     /'; FAIL=$((FAIL+1))
fi
OUT="$(GULLFIRE_OVERTURE_RELEASES="2026-09-23.0" uv run --quiet --with numpy --with shapely Tools/fetch_city.py chicago --out "$FD" --overture-release 2025-01-01.0 2>&1)"; CODE=$?
if [ "$CODE" -eq 1 ] && echo "$OUT" | grep -q "2025-01-01.0 is no longer published"; then
    echo "ok   a named release that is gone stops too"; PASS=$((PASS+1))
else
    echo "FAIL a named release that is gone stops too (exit $CODE)"; FAIL=$((FAIL+1))
fi
rm -rf "$FD"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
