#!/usr/bin/env bash
set -euo pipefail

WORKDIR="$HOME/mesa-dates"
BUILDER="/caminho/para/o/seu/build.sh"   # ajuste aqui

mkdir -p "$WORKDIR"

if [ ! -d "$WORKDIR/mesa" ]; then
    git clone https://gitlab.freedesktop.org/mesa/mesa.git "$WORKDIR/mesa"
fi

cd "$WORKDIR/mesa"
git fetch origin

START="2026-07-09"
END="2026-07-15"

count=0

for day in $(seq 9 15); do
    date=$(printf "2026-07-%02d" "$day")

    commit=$(git rev-list -1 --before="${date} 23:59:59" origin/main)

    if [ -z "$commit" ]; then
        continue
    fi

    git checkout -f "$commit"

    short=$(git rev-parse --short HEAD)

    echo "===================================="
    echo "Data   : $date"
    echo "Commit : $short"
    git log -1 --oneline
    echo "===================================="

    MESA_SOURCE="$WORKDIR/mesa" \
    BISECT_MODE=1 \
    BUILD_VERSION="$date-$short" \
    bash "$BUILDER"

    count=$((count + 1))

    if [ "$count" -ge 5 ]; then
        echo "Foram compilados 5 Turnips."
        echo "Teste-os e depois execute o script novamente para os próximos."
        break
    fi
done
