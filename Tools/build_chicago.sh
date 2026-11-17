#!/usr/bin/env bash
# Build Gullfire's Chicago map from open data, in one command, from an empty Cities/ folder,
# then install it where the app looks for it.
#
#   Tools/build_chicago.sh [--dest DIR] [--no-install] [--force]
#
# Needs the network once (for the map data), uv and Xcode 27. Steps:
#   1. fetch the Overture and OpenStreetMap data for Chicago (Tools/fetch_city.py)
#   2. pack the city package (gullfire-pack)
#   3. write the Scenic route (Tools/make_routes.py)
#   4. write the River route (gullfire-pack routes)
#   5. write the street routes for seeds 1 to 6
#   6. install the package (rsync, without raw/) into the app's folder
#
# The build is Cities/Chicago in this project (git-ignored). The install goes to
# ~/Library/Application Support/Gullfire/Cities/Chicago unless --dest or GULLFIRE_INSTALL_DIR
# names another folder. Running it again redoes the steps; downloaded data is kept.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CITY_DIR="Cities/Chicago"
DEFAULT_DEST="$HOME/Library/Application Support/Gullfire/Cities/Chicago"
MARKER=".gullfire-installed-by-build"
DEST="${GULLFIRE_INSTALL_DIR:-$DEFAULT_DEST}"
INSTALL=1
FORCE=0
START=$SECONDS
STEP="setup"

usage() {
    cat <<'EOF'
usage: Tools/build_chicago.sh [--dest DIR] [--no-install] [--force]

  --dest DIR     install into DIR (the Chicago folder itself) instead of the app's folder.
                 GULLFIRE_INSTALL_DIR does the same.
  --no-install   build Cities/Chicago only; do not copy it anywhere.
  --force        replace a folder at the destination that this script did not create. The old
                 folder is moved aside (named ...before-build-<time>), not deleted. Never
                 replaces a symbolic link; a link is always left alone and reported.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dest) [ $# -ge 2 ] || { echo "--dest needs a folder" >&2; exit 2; }; DEST="$2"; shift 2 ;;
        --no-install) INSTALL=0; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

fmt() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

trap 'echo "" >&2; echo "FAILED during: $STEP (after $(fmt $((SECONDS - START))))" >&2' ERR

run_step() {  # run_step "what it does" command...
    STEP="$1"; shift
    echo ""
    echo "==> $STEP"
    local t0=$SECONDS
    "$@"
    echo "    done in $(fmt $((SECONDS - t0)))"
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
    printf 'Installed by Tools/build_chicago.sh. The next build replaces this folder; move it aside to keep it.\n' > "$building/$MARKER"

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

run_step "1/6 Fetch the Chicago map data (network)" \
    uv run --with overturemaps --with numpy --with shapely Tools/fetch_city.py chicago
run_step "2/6 Pack the city package" \
    swift run -c release gullfire-pack "$CITY_DIR"
run_step "3/6 Write the Scenic route" \
    python3 Tools/make_routes.py "$CITY_DIR"
run_step "4/6 Write the River route" \
    swift run -c release gullfire-pack routes "$CITY_DIR"
run_step "5/6 Write the street routes, seeds 1 to 6" \
    uv run --with numpy --with shapely Tools/make_street_routes.py "$CITY_DIR" --seeds 1 2 3 4 5 6

TOTAL_KB=$(du -sk "$CITY_DIR" | awk '{print $1}')
RAW_KB=$(du -sk "$CITY_DIR/raw" 2>/dev/null | awk '{print $1}' || echo 0)
PACKAGE_MB=$(( (TOTAL_KB - ${RAW_KB:-0}) / 1024 ))
echo ""
echo "Chicago is built in $CITY_DIR. Build time $(fmt $((SECONDS - START))), package about ${PACKAGE_MB} MB (raw/ not counted)."

if [ "$INSTALL" -eq 1 ]; then
    install_package || { echo "The build is in $CITY_DIR; the install did not happen (see above)." >&2; exit 1; }
    echo "Gullfire opens this map from the Dock or Finder, or from the project folder."
else
    echo "Not installed (--no-install). To use it, run again without --no-install or copy $CITY_DIR (without raw/) to the app's folder."
fi
