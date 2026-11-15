#!/bin/sh
# Refreshes the filter-list snapshot bundled with the app (used until the first download).
set -eu
cd "$(dirname "$0")/../Unreel/Resources/DefaultFilters"
fetch() { curl -fsSL --max-time 60 -o "$1.txt" "$2" && echo "$1: $(wc -c < "$1.txt") bytes"; }
fetch ublock-filters     https://ublockorigin.github.io/uAssets/filters/filters.min.txt
fetch ublock-quick-fixes https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt
fetch ublock-privacy     https://ublockorigin.github.io/uAssets/filters/privacy.min.txt
fetch ublock-unbreak     https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt
fetch easylist           https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt
fetch easyprivacy        https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt
