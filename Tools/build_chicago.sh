#!/usr/bin/env bash
# Build Gullfire's Chicago map in one command. This is Tools/build_city.sh chicago --yes: the
# preflight prints first and refuses on a Mac below Chicago's memory or free disk (unless --force).
# All the steps, checks and the install are in Tools/build_city.sh.
#
#   Tools/build_chicago.sh [--dest DIR] [--no-install] [--force]
#
# Needs the network once (for the map data), uv and Xcode 27. The build is Cities/Chicago; the
# install goes to ~/Library/Application Support/Gullfire/Cities/Chicago unless --dest or
# GULLFIRE_INSTALL_DIR names another folder.
#
# Chicago is installed without asking. For the other maps, use Tools/build_city.sh <id>.
usage() {
    cat <<'EOF'
usage: Tools/build_chicago.sh [--dest DIR] [--no-install] [--force]

  --dest DIR     install into DIR (the Chicago folder itself) instead of the app's folder.
                 GULLFIRE_INSTALL_DIR does the same.
  --no-install   build Cities/Chicago only; do not copy it anywhere.
  --force        go on when this Mac is below Chicago's memory or free-disk needs, and replace a
                 folder at the destination that the build did not create (moved aside, not deleted).
                 Never replaces a symbolic link.

Runs Tools/build_city.sh chicago --yes, which takes the same options (and --check-only).
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT/Tools/build_city.sh" chicago --yes "$@"
