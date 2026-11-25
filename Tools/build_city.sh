#!/usr/bin/env bash
# Build one of Gullfire's city maps from open data, in one command, then install it where the
# app looks for it. The public maps and their needs are in Resources/Recipes/recipes.json, which
# this script and the app's Settings > Maps both read.
#
#   Tools/build_city.sh <id> [--build-dir DIR] [--overture-release latest|ID] [--dest DIR] [--no-install] [--force] [--yes] [--check-only]
#
#   <id>   chicago, chicagowide, chicagocity or cookcounty (the ids in recipes.json)
#
# Before anything is downloaded it prints what the map needs (download, disk, build memory,
# minutes) and checks this Mac's memory and free disk against the recipe. Too small: it says
# what the map needs and what this Mac has, and stops with nothing downloaded, unless --force.
# Then it asks before the download (--yes skips the question). Steps:
#   1. fetch the map's data (network) (Tools/fetch_city.py)
#   2. pack the city package (gullfire-pack; out of core for the wide maps)
#   3. write the Scenic route (Tools/make_routes.py)
#   4. write the River route (gullfire-pack routes)
#   5. write the street routes for seeds 1 to 6 (Tools/make_street_routes.py)
#   6. write the street graph (streets.json), which endless flight and picking a street use
#   7. mark which of its streets can start a loop (gullfire-pack loops)
#   8. install the package (rsync, without raw/) into the app's folder
#
# The build is Cities/<folder> in this project (git-ignored), or <DIR>/<folder> with --build-dir. The install goes to
# ~/Library/Application Support/Gullfire/Cities/<folder> unless --dest or GULLFIRE_INSTALL_DIR
# names another folder. Running it again redoes the steps; downloaded data is kept.
#
# Exit codes: 0 done (or --check-only and this Mac can build it), 1 a step failed or the
# build was not confirmed, 2 usage or unknown id, 3 this Mac is below the map's needs.
#
# Tests, which download nothing: Tools/test_build_city.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RECIPES="$ROOT/Resources/Recipes/recipes.json"
MARKER=".gullfire-installed-by-build"
DEST_OVERRIDE=""
BUILD_DIR=""
OVERTURE=""
INSTALL=1
FORCE=0
YES=0
CHECK_ONLY=0
ID=""
START=$SECONDS
STEP="setup"

usage() {
    cat <<'EOF'
usage: Tools/build_city.sh <id> [--build-dir DIR] [--overture-release latest|ID] [--dest DIR] [--no-install] [--force] [--yes] [--check-only]

  <id>           chicago, chicagowide, chicagocity or cookcounty (the ids in Resources/Recipes/recipes.json)
  --build-dir DIR build in DIR/<folder> instead of Cities/<folder>. If DIR/<folder>/raw is
                 already there (for example an APFS clone, cp -c, of an earlier download), the
                 fetch step keeps it and downloads only what is missing.
  --overture-release latest|ID
                 the Overture data release to download. The default is the one the maps were
                 tested on (named in Resources/Recipes/recipes.json). If it is no longer published
                 the script stops before downloading; "latest" then builds from the newest release,
                 which has not been tested with Gullfire. Data already in raw/ is kept as it is.
  --dest DIR     install into DIR (the city folder itself) instead of the app's folder.
                 GULLFIRE_INSTALL_DIR does the same.
  --no-install   build Cities/<folder> only; do not copy it anywhere.
  --force        go on when this Mac is below the map's memory or free-disk needs (a warning is
                 printed), and replace a folder at the destination that this script did not create.
                 The old folder is moved aside (named ...before-build-<time>), not deleted. Never
                 replaces a symbolic link; a link is always left alone and reported.
  --yes          do not ask "Continue?" before the download (for scripts).
  --check-only   print the preflight and the check, then stop: exit 0 if this Mac can build the
                 map, 3 if not. Downloads and builds nothing.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build-dir) [ $# -ge 2 ] || { echo "--build-dir needs a folder" >&2; exit 2; }; BUILD_DIR="$2"; shift 2 ;;
        --overture-release) [ $# -ge 2 ] || { echo "--overture-release needs latest or a release id" >&2; exit 2; }; OVERTURE="$2"; shift 2 ;;
        --dest) [ $# -ge 2 ] || { echo "--dest needs a folder" >&2; exit 2; }; DEST_OVERRIDE="$2"; shift 2 ;;
        --no-install) INSTALL=0; shift ;;
        --force) FORCE=1; shift ;;
        --yes) YES=1; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [ -n "$ID" ]; then echo "only one map id can be given" >&2; usage >&2; exit 2; fi
            ID="$1"; shift ;;
    esac
done

fmt() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

trap 'echo "" >&2; echo "FAILED during: $STEP (after $(fmt $((SECONDS - START))))" >&2' ERR

# Reads recipes.json with the standard library only. "--ids" lists the ids; otherwise prints one
# recipe as tab-separated fields. Exit 4 when the id is not in the list.
PY_RECIPE='
import json, sys
recipes = json.load(open(sys.argv[1], encoding="utf-8"))["recipes"]
if sys.argv[2] == "--ids":
    print(" ".join(r["id"] for r in recipes))
    sys.exit(0)
hit = [r for r in recipes if r["id"] == sys.argv[2]]
if not hit:
    sys.exit(4)
r = hit[0]
cols = ["id", "folder", "displayName", "areaKm2", "downloadMB", "diskGB", "freeDiskGB",
        "minRamGB", "buildPeakGB", "approxMinutes"]
print("\t".join([str(r[c]) for c in cols] + ["1" if r["outOfCore"] else "0"]))
'

if [ -z "$ID" ]; then
    usage >&2
    exit 2
fi
if ! VALID_IDS="$(python3 -I -c "$PY_RECIPE" "$RECIPES" --ids)"; then
    echo "cannot read the map list at $RECIPES" >&2
    exit 1
fi
if ! REC="$(python3 -I -c "$PY_RECIPE" "$RECIPES" "$ID")"; then
    echo "unknown map id: $ID" >&2
    echo "valid ids: $VALID_IDS" >&2
    exit 2
fi
IFS=$'\t' read -r R_ID R_FOLDER R_NAME R_AREA R_DL_MB R_DISK_GB R_FREE_GB R_MIN_RAM R_PEAK_GB R_MINUTES R_OOC <<< "$REC"

if [ -n "$BUILD_DIR" ]; then
    mkdir -p "$BUILD_DIR"
    CITIES_DIR="$(cd "$BUILD_DIR" && pwd)"
else
    CITIES_DIR="$ROOT/Cities"
fi
CITY_DIR="$CITIES_DIR/$R_FOLDER"
DEFAULT_DEST="$HOME/Library/Application Support/Gullfire/Cities/$R_FOLDER"
DEST="${DEST_OVERRIDE:-${GULLFIRE_INSTALL_DIR:-$DEFAULT_DEST}}"

# ---- preflight: what the map needs, what this Mac has --------------------------------------

if [ -n "${GULLFIRE_FAKE_RAM_GB:-}" ]; then
    RAM_GB="$GULLFIRE_FAKE_RAM_GB"
else
    RAM_GB="$(awk -v b="$(sysctl -n hw.memsize)" 'BEGIN { printf "%.1f", b / 1073741824 }')"
fi
if [ -n "${GULLFIRE_FAKE_FREE_GB:-}" ]; then
    FREE_GB="$GULLFIRE_FAKE_FREE_GB"
else
    FREE_GB="$(df -Pk "$ROOT" | awk 'NR == 2 { printf "%.1f", $4 / 1048576 }')"
fi
RAM_OK="$(awk -v a="$RAM_GB" -v b="$R_MIN_RAM" 'BEGIN { print (a + 0 >= b + 0) ? 1 : 0 }')"
DISK_OK="$(awk -v a="$FREE_GB" -v b="$R_FREE_GB" 'BEGIN { print (a + 0 >= b + 0) ? 1 : 0 }')"

echo "Map: $R_NAME"
echo "  id              $R_ID, folder $CITY_DIR"
echo "  area            $R_AREA km2"
echo "  download        $R_DL_MB MB"
echo "  disk needed     $R_DISK_GB GB (this Mac needs $R_FREE_GB GB free)"
echo "  build memory    $R_PEAK_GB GB at peak (this Mac needs $R_MIN_RAM GB of memory)"
echo "  time            about $R_MINUTES minutes"
echo ""
echo "This Mac:"
if [ "$RAM_OK" -eq 1 ]; then RAM_STATE="ok"; else RAM_STATE="too low"; fi
if [ "$DISK_OK" -eq 1 ]; then DISK_STATE="ok"; else DISK_STATE="too low"; fi
echo "  memory          $RAM_GB GB : $RAM_STATE"
echo "  free disk       $FREE_GB GB on the volume with this project : $DISK_STATE"

if [ "$RAM_OK" -ne 1 ] || [ "$DISK_OK" -ne 1 ]; then
    echo ""
    echo "This Mac is too small for $R_ID. The map needs $R_MIN_RAM GB of memory and $R_FREE_GB GB"
    echo "free disk; this Mac has $RAM_GB GB of memory and $FREE_GB GB free disk."
    if [ "$FORCE" -ne 1 ]; then
        echo "Nothing was downloaded. Use --force to try anyway (it may run out of memory or disk partway through)."
        exit 3
    fi
    echo "WARNING: going on because of --force. The build may run out of memory or disk partway through."
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    echo "Check only: stopping here. Nothing was downloaded or built."
    exit 0
fi

# ---- confirm before the download ------------------------------------------------------------

if [ "$YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo "Standard input is not a terminal and --yes was not given. Nothing was downloaded." >&2
        echo "Run again with --yes to build without the question." >&2
        exit 1
    fi
    printf 'Continue? [y/N] '
    ANSWER=""
    read -r ANSWER || true
    case "$ANSWER" in
        y|Y) ;;
        *) echo "Stopped. Nothing was downloaded."; exit 1 ;;
    esac
fi

# ---- build ----------------------------------------------------------------------------------

run_step() {  # run_step "what it does" command...
    STEP="$1"; shift
    echo ""
    echo "==> $STEP"
    local t0=$SECONDS timing; timing="$(mktemp)"
    # /usr/bin/time -l reports the largest resident size of the step and everything it started.
    /usr/bin/time -l -o "$timing" "$@"
    local peak; peak="$(awk '/maximum resident set size/ { printf "%.1f", $1 / 1073741824 }' "$timing")"
    rm -f "$timing"
    echo "    done in $(fmt $((SECONDS - t0))), peak memory ${peak:-?} GB"
}

# Copies the package into DEST. Refuses, and changes nothing, where writing would go through a
# symbolic link or would replace a folder this script did not make (unless --force).
install_package() {
    STEP="install the package"
    echo ""
    echo "==> $STEP"
    local t0=$SECONDS

    if [ -L "$DEST" ]; then
        echo "    NOT INSTALLED: $DEST is a symbolic link (to $(readlink "$DEST")). It was left alone." >&2
        echo "    Remove the link yourself, or pass --dest with another folder." >&2
        return 1
    fi
    local parent; parent="$(dirname "$DEST")"
    local grand; grand="$(dirname "$parent")"
    if [ -L "$parent" ] || [ -L "$grand" ]; then
        echo "    NOT INSTALLED: a folder above $DEST is a symbolic link. Nothing was written." >&2
        echo "    Pass --dest with a folder that is not reached through a link." >&2
        return 1
    fi
    if [ -e "$DEST" ] && [ ! -f "$DEST/$MARKER" ]; then
        if [ "$FORCE" -ne 1 ]; then
            echo "    NOT INSTALLED: $DEST already exists and this script did not create it." >&2
            echo "    Move it yourself, or run again with --force (the old folder is moved aside, not deleted)." >&2
            return 1
        fi
        local aside="$DEST.before-build-$(date +%Y%m%d-%H%M%S)"
        mv "$DEST" "$aside"
        echo "    moved the existing folder aside: $aside"
    fi

    # Copy into a hidden sibling first. The app only ever opens $DEST, so a copy that is
    # interrupted leaves no half package where the app looks; the swap at the end is two renames.
    local base; base="$(basename "$DEST")"
    local building="$parent/.$base.building.$$"
    for stale in "$parent/.$base".building.*; do
        [ -e "$stale" ] && rm -rf "$stale"
    done
    mkdir -p "$parent"
    if ! rsync -a --exclude raw "$CITY_DIR/" "$building/"; then
        rm -rf "$building"
        echo "    NOT INSTALLED: the copy failed. $DEST was not changed." >&2
        return 1
    fi
    printf 'Installed by Tools/build_city.sh. The next build replaces this folder; move it aside to keep it.\n' > "$building/$MARKER"

    if [ -e "$DEST" ]; then
        local old="$parent/.$base.replaced.$$"
        mv "$DEST" "$old"
        mv "$building" "$DEST"
        rm -rf "$old"
    else
        mv "$building" "$DEST"
    fi
    echo "    installed to $DEST (raw/ left out)"
    echo "    done in $(fmt $((SECONDS - t0)))"
}

command -v uv >/dev/null || { echo "uv is needed (https://docs.astral.sh/uv/)" >&2; exit 1; }
command -v swift >/dev/null || { echo "swift is needed (Xcode 27)" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync is needed (it ships with macOS)" >&2; exit 1; }

# The wide maps (outOfCore in recipes.json) pack out of core and cap the street-route generator.
OUT_OF_CORE=0
[ "$R_OOC" = "1" ] && OUT_OF_CORE=1

run_step "1/7 Fetch the $R_FOLDER map data (network)" \
    uv run --with overturemaps --with numpy --with shapely Tools/fetch_city.py "$R_ID" --out "$CITIES_DIR" ${OVERTURE:+--overture-release "$OVERTURE"}

if [ "$OUT_OF_CORE" -eq 1 ]; then
    run_step "2/7 Pack the city package (out of core)" \
        env GULLFIRE_OUT_OF_CORE=1 swift run -c release gullfire-pack "$CITY_DIR"
else
    run_step "2/7 Pack the city package" \
        swift run -c release gullfire-pack "$CITY_DIR"
fi

# Checked 2026-11-23 on the script's own output for all three wide maps: Scenic and River, flown for a whole
# lap or more, pass the same gates as Chicago's (zero nudges, zero seconds outside, clearance above 50 m, bank 45 degrees at most).
run_step "3/7 Write the Scenic route" \
    python3 Tools/make_routes.py "$CITY_DIR"
run_step "4/7 Write the River route" \
    swift run -c release gullfire-pack routes "$CITY_DIR"

if [ "$OUT_OF_CORE" -eq 1 ]; then
    # Seeds 1 to 6 finish under the guard on ChicagoCity and Cook County (peak 5.6 GB, 2026-11-23).
    run_step "5/7 Write the street routes, seeds 1 to 6 (memory guard 8 GB)" \
        uv run --with numpy --with shapely Tools/make_street_routes.py "$CITY_DIR" --seeds 1 2 3 4 5 6 --max-gb 8
else
    run_step "5/7 Write the street routes, seeds 1 to 6" \
        uv run --with numpy --with shapely Tools/make_street_routes.py "$CITY_DIR" --seeds 1 2 3 4 5 6
fi

# Steps 6 and 7 on the wide maps give the same street graph and loop marks the soaks used (2026-11-23).
run_step "6/7 Write the street graph" \
    uv run --with numpy --with shapely Tools/make_street_graph.py "$CITY_DIR"

run_step "7/7 Mark the streets that can start a loop" \
    swift run -c release gullfire-pack loops "$CITY_DIR"

TOTAL_KB=$(du -sk "$CITY_DIR" | awk '{print $1}')
RAW_KB=$(du -sk "$CITY_DIR/raw" 2>/dev/null | awk '{print $1}')
RAW_KB=${RAW_KB:-0}
PACKAGE_MB=$(( (TOTAL_KB - RAW_KB) / 1024 ))
echo ""
echo "$R_FOLDER is built in $CITY_DIR. Build time $(fmt $((SECONDS - START))), package about ${PACKAGE_MB} MB (raw/ not counted)."

if [ "$INSTALL" -eq 1 ]; then
    install_package || { echo "The build is in $CITY_DIR; the install did not happen (see above)." >&2; exit 1; }
    echo "Gullfire opens this map from the Dock or Finder, or from the project folder."
else
    echo "Not installed (--no-install). To use it, run again without --no-install or copy $CITY_DIR (without raw/) to the app's folder."
fi
