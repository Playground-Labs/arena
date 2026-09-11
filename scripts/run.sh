#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
scripts/build.sh
export ARENA_DATA_DIR="${ARENA_DATA_DIR:-$PWD/.context/arena-data}"
export ARENA_PORT="${ARENA_PORT:-${CONDUCTOR_PORT:-42424}}"
exec .context/DerivedData/Build/Products/Debug/Arena.app/Contents/MacOS/Arena
