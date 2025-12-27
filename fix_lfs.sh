#!/usr/bin/env bash
set -e

for d in */; do
  if [ -d "$d/.git" ]; then
    echo "=== Fixing LFS in $d ==="
    cd "$d"
    git lfs install --force
    git lfs fetch --all
    git lfs checkout
    cd ..
  fi
done

echo "Done. All repos processed."
