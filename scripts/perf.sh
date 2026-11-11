#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# What the painting costs, and whether a change to it left the picture alone.
#
# Usage: scripts/perf.sh <command> [name]
#   keep     copies this checkout's release build to build/perf/<name>, to compare later builds against
#   bench    GPU time a frame in every place, by day and by night, this build and the kept one in turn
#   frames   paints the same scenes with both builds and compares them pixel by pixel
#   memory   the footprint of both builds part way through a flight, and how much of it is GPU memory
#   compile  how long the shaders of both builds take to compile from cold
#   soak     paints stills over and over, stopping at the first GPU error: scripts/perf.sh soak 300
#   steady   paints one frame over and over and fails unless it comes out the same every time: scripts/perf.sh steady 1200
#   check    bench, frames, memory and compile together; fails if this build costs more or paints differently
#
# <name> is "before" unless given. A usual round: `scripts/perf.sh keep` on the commit to compare against, then
# `scripts/perf.sh check` after each change, and `scripts/perf.sh steady` after any change to the shaders. ROUNDS sets
# how many times bench goes round (3), and PLACES which places it flies over. Numbers move with whatever else the Mac
# is doing, so the two builds always take turns, and only a difference seen every round counts.

command="${1:-}"
name="${2:-before}"
kept="build/perf/$name"
read -r -a places <<< "${PLACES:-punjab niigata serengeti pampa lapland normandy lisse kansas}"
size=(--size 1512x982 --scale 2)
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

build() {
    swift build -c release --arch arm64 --product Outbound >/dev/null
    now="$(swift build -c release --arch arm64 --show-bin-path)"
}

needs_kept() {
    [[ -x "$kept/Outbound" ]] || { echo "Nothing kept as \"$name\": run scripts/perf.sh keep $name on the build to compare against." >&2; exit 2; }
}

# The mean GPU time of a frame over a short flight, in milliseconds.
frame_time() {
    local line
    line="$("$1/Outbound" --render /dev/null --best --bench 20 "${size[@]}" "${@:2}" 2>&1 | tail -1)"
    [[ "$line" == *" mean "* ]] || { echo "$1/Outbound failed: $line" >&2; kill -TERM $$; }
    sed -nE 's/.*mean ([0-9.]+) ms.*/\1/p' <<< "$line"
}

bench() {
    local rounds="${ROUNDS:-3}" results="$scratch/bench"
    : > "$results"
    for ((round = 1; round <= rounds; round++)); do
        for place in "${places[@]}"; do
            for light in day night; do
                local hour=()
                [[ "$light" == night ]] && hour=(--hour 23)
                for which in kept now; do
                    local dir="$kept"
                    [[ "$which" == now ]] && dir="$now"
                    echo "$which $place $light $(frame_time "$dir" --place "$place" ${hour[@]+"${hour[@]}"})" >> "$results"
                done
            done
        done
    done
    awk -v name="$name" '
        { sum[$1, $2, $3] += $4; n[$1, $2, $3]++; total[$1] += $4; count[$1]++
          if (!(($2, $3) in seen)) { seen[$2, $3] = 1; order[++rows] = $2 " " $3 } }
        END {
            printf "%-18s %10s %10s %8s\n", "ms a frame", name, "now", "change"
            for (i = 1; i <= rows; i++) {
                split(order[i], key, " ")
                a = sum["kept", key[1], key[2]] / n["kept", key[1], key[2]]
                b = sum["now", key[1], key[2]] / n["now", key[1], key[2]]
                printf "%-18s %10.3f %10.3f %+7.1f%%\n", order[i], a, b, (b / a - 1) * 100
            }
            a = total["kept"] / count["kept"]; b = total["now"] / count["now"]
            printf "%-18s %10.3f %10.3f %+7.1f%%\n", "all", a, b, (b / a - 1) * 100
            printf "%.4f\n", b / a > "/dev/stderr"
        }' "$results" 2> "$scratch/ratio"
}

# Megabytes of footprint and of GPU memory, eight seconds into a long flight.
footprint_of() {
    "$1/Outbound" --render /dev/null --place lapland --best --time 150 --bench 3000 "${size[@]}" >/dev/null 2>&1 &
    local pid=$!
    perl -e 'select(undef, undef, undef, 8)'
    footprint "$pid" 2>/dev/null | awk '
        function megabytes(value, unit) {
            return int(value * (unit == "KB" ? 1 / 1024 : unit == "GB" ? 1024 : unit == "MB" ? 1 : 0) + 0.5)
        }
        /phys_footprint:/ { total = megabytes($2, $3) }
        /Owned physical footprint \(unmapped\) \(graphics\)/ { graphics = megabytes($1, $2) }
        END { print total, graphics }'
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

memory() {
    read -r kept_total kept_graphics <<< "$(footprint_of "$kept")"
    read -r now_total now_graphics <<< "$(footprint_of "$now")"
    # A flight that died before it could be read leaves nothing to compare, which must never pass for no growth.
    local read
    for read in "$kept_total" "$kept_graphics" "$now_total" "$now_graphics"; do
        [[ "$read" =~ ^[1-9][0-9]*$ ]] || { echo "Couldn't read the footprint of a flight: did it start?" >&2; exit 1; }
    done
    printf "%-18s %10s %10s\n" "megabytes" "$name" "now"
    printf "%-18s %10s %10s\n" "footprint" "$kept_total" "$now_total"
    printf "%-18s %10s %10s\n" "GPU memory" "$kept_graphics" "$now_graphics"
}

# Seconds the shaders take to compile when the system has never seen them. Metal keeps what it has compiled, and
# knows a shader again however its text is spelt, so a copy gets a value changed a hair: one every shader uses.
cold_compile() {
    local copy="$scratch/cold-$RANDOM"
    mkdir -p "$copy"
    cp -R "$1/Outbound" "$1/Outbound_Outbound.bundle" "$copy/"
    [[ -d "$1/Sparkle.framework" ]] && cp -R "$1/Sparkle.framework" "$copy/"
    local salt
    salt="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    local common="$copy/Outbound_Outbound.bundle/Contents/Resources/Shaders/Common.metal"
    [[ -f "$common" ]] || common="$(find "$copy/Outbound_Outbound.bundle" -name Common.metal | head -1)"
    grep -q '0\.299, 0\.587, 0\.114' "$common" || { echo "The line this changes has moved in Common.metal." >&2; exit 2; }
    sed -i '' -E "s/0\.299, 0\.587, 0\.114/0.299, 0.587, 0.114$(printf '%06d' $((salt % 1000000)))/" "$common"
    # With the whole shaders only, which are all that opening the app waits for.
    local run=("$copy/Outbound" --render /dev/null --bench 0.2 --size 400x300 --scale 1 --whole)
    # Seconds a run takes, or nothing if it fails: a build that falls over at once would otherwise look quick.
    local timed='$t = time; $failed = system(@ARGV); exit 1 if $failed; printf "\n%.2f\n", time - $t'
    local cold warm
    cold="$(perl -MTime::HiRes=time -e "$timed" "${run[@]}" 2>/dev/null | tail -1)" || true
    warm="$(perl -MTime::HiRes=time -e "$timed" "${run[@]}" 2>/dev/null | tail -1)" || true
    [[ "$cold" =~ ^[0-9.]+$ && "$warm" =~ ^[0-9.]+$ ]] || { echo "$1/Outbound didn't run." >&2; exit 1; }
    awk -v cold="$cold" -v warm="$warm" 'BEGIN { printf "%.2f\n", cold - warm }'
}

compile() {
    kept_compile="$(cold_compile "$kept")"
    now_compile="$(cold_compile "$now")"
    printf "%-18s %10s %10s\n" "seconds" "$name" "now"
    printf "%-18s %10s %10s\n" "cold compile" "$kept_compile" "$now_compile"
}

# Scenes that between them reach every part of the frame: each place by day and after dark, one place giving way to
# the next, a Fly To, a train, a flock, the bird after the pointer, and a display that isn't Retina.
scenes() {
    for place in "${places[@]}"; do
        echo "$place by day|--place $place"
        echo "$place at night|--place $place --hour 23"
    done
    echo "one place to the next|--place punjab --find handover"
    echo "fly to|--place punjab --fly-to lisse --fly-at 0.5"
    echo "train|--place normandy --find train"
    echo "train at night|--place normandy --hour 23 --find train"
    echo "flock|--place serengeti --find flock"
    echo "bird after the pointer|--place kansas --cursor"
    echo "plain display|--place niigata --size 1280x720 --scale 1 --density 1.5 --ground-filter box"
}

frames() {
    local differ="build/perf/framediff"
    if [[ ! -x "$differ" || scripts/framediff.swift -nt "$differ" ]]; then
        mkdir -p build/perf
        swiftc -O scripts/framediff.swift -o "$differ"
    fi
    local failed=0
    while IFS='|' read -r scene arguments; do
        local width=3024 height=1964
        [[ "$arguments" == *"--size 1280x720"* ]] && { width=1280; height=720; }
        local options=("${size[@]}")
        [[ "$arguments" == *"--size"* ]] && options=()
        # shellcheck disable=SC2086
        "$kept/Outbound" --render - --best --seconds 3 --fps 2 ${options[@]+"${options[@]}"} $arguments > "$scratch/a.raw" 2>/dev/null
        # shellcheck disable=SC2086
        "$now/Outbound" --render - --best --seconds 3 --fps 2 ${options[@]+"${options[@]}"} $arguments > "$scratch/b.raw" 2>/dev/null
        printf "%-26s " "$scene"
        if ! "$differ" "$scratch/a.raw" "$scratch/b.raw" "$width" "$height"; then
            failed=1
            # Kept to look at: a difference that comes once and never again can't be told from one that does otherwise.
            local evidence="build/perf/differed/${scene// /-}"
            mkdir -p "$evidence"
            cp "$scratch/a.raw" "$evidence/$name.raw"
            cp "$scratch/b.raw" "$evidence/now.raw"
            echo "    kept both in $evidence (raw BGRA, ${width}x${height}, 6 frames)"
        fi
    done < <(scenes)
    rm -f "$scratch/a.raw" "$scratch/b.raw"
    return "$failed"
}

soak() {
    local runs="${1:-300}"
    for ((i = 1; i <= runs; i++)); do
        local place="${places[$((i % ${#places[@]}))]}"
        if ! output="$("$now/Outbound" --render /dev/null --place "$place" --best --time $((20 + i * 7)) --bench 0.2 "${size[@]}" 2>&1)" \
            || grep -qiE 'error|hang' <<< "$output"; then
            echo "Run $i ($place) failed:"
            echo "$output"
            exit 1
        fi
        ((i % 25 == 0)) && echo "$i runs clean"
    done
    echo "All $runs runs clean"
}

# The ground's shader is the largest by far, and how Metal compiles it turns on things that have nothing to do with
# it: once, after a change elsewhere in its library, it painted a block of eight texels by four wrong in about one
# painting of a screen in two hundred. A handful of pictures never shows that. So this paints one frame over and
# over, four at a time, each in a process of its own as the first painting is where it showed, and counts the
# different pictures that come out. There should be one.
steady() {
    local runs="${1:-1200}"
    export steady_run="$now/Outbound"
    local pictures
    pictures="$(seq 1 "$runs" | xargs -P 4 -n 1 /bin/bash -c \
        '"$steady_run" --render - --best --place normandy --seconds 0.5 --fps 2 --size 1512x982 --scale 2 2>/dev/null | md5 -q' _ \
        | sort | uniq -c | sort -rn)"
    echo "$pictures"
    if [[ "$(grep -c . <<< "$pictures")" != 1 ]]; then
        echo "The same frame came out more than one way."
        exit 1
    fi
    echo "All $runs paintings came out the same"
}

case "$command" in
keep)
    build
    rm -rf "$kept"
    mkdir -p "$kept"
    cp -R "$now/Outbound" "$now/Outbound_Outbound.bundle" "$kept/"
    [[ -d "$now/Sparkle.framework" ]] && cp -R "$now/Sparkle.framework" "$kept/"
    echo "Kept $(git rev-parse --short HEAD) as \"$name\""
    ;;
bench) needs_kept; build; bench ;;
frames) needs_kept; build; frames ;;
memory) needs_kept; build; memory ;;
compile) needs_kept; build; compile ;;
soak) build; soak "${2:-300}" ;;
steady) build; steady "${2:-1200}" ;;
check)
    needs_kept
    build
    failed=0
    frames || { echo "The picture changed."; failed=1; }
    echo
    bench
    # More than a twentieth slower is no accident of the moment.
    awk '{ exit !($1 > 1.05) }' "$scratch/ratio" && { echo "Frames cost more."; failed=1; }
    echo
    memory
    # GPU memory moves in lumps of about 4 MB.
    (( now_graphics > kept_graphics + 4 )) && { echo "GPU memory grew."; failed=1; }
    echo
    compile
    # Two readings of one build can be a few tenths apart.
    awk -v a="$kept_compile" -v b="$now_compile" 'BEGIN { exit !(b > a + 0.5) }' && { echo "Shaders take longer to compile."; failed=1; }
    exit "$failed"
    ;;
*)
    sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
