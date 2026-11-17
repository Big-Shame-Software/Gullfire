#!/bin/zsh
# Copies Big Shame Gadgets (BSSImageOptimizer and friends) into the app's Packages/Gadgets, and records a fingerprint of what was copied in GADGETS-VERSION.
# The package is a fixed-version copy: change Gadgets, then run this again. Never edit Packages/Gadgets by hand.
# Usage: scripts/update-gadgets.sh /path/to/Gadgets
set -eu
cd "$(dirname "$0")/.."
src=${1:-}
[[ -n $src && -f $src/Package.swift && -d $src/Sources ]] || { echo "usage: scripts/update-gadgets.sh /path/to/Gadgets" >&2; exit 2 }
dest=Packages/Gadgets
mkdir -p $dest
# Only the package itself: no .build, no local files.
rm -rf $dest/Sources $dest/Tests $dest/Art
cp $src/Package.swift $src/LICENSE $src/README.md $dest/
cp -R $src/Sources $src/Tests $src/Art $dest/
find $dest -name .DS_Store -delete
fingerprint=$(cd $dest && find Package.swift Sources Tests Art -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-12)
printf 'Gadgets, sources fingerprint %s\nA fixed-version copy. Do not edit here: change Gadgets, then run scripts/update-gadgets.sh.\n' $fingerprint > $dest/GADGETS-VERSION
echo "Packages/Gadgets is now Gadgets $fingerprint"
