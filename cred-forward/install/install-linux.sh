#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
exec "$script_dir/_install.sh" Linux "${1:-}"
