#!/bin/sh
#
# Launch one pingpong_server_cores instance per core listed in TASKSET_LIST.
#
# Invoked remotely as: sudo sh multi_cores_helper.sh <args...>

set -e
ulimit -n 65536

echo "=== multi_cores_helper.sh debug ===" >&2
echo "argv0=$0" >&2
echo "shell=$SHELL  bash=$BASH_VERSION" >&2
echo "first10=[$1][$2][$3][$4][$5][$6][$7][$8][$9][${10}]" >&2


TASKSET_LIST=$1
REPO=$2   # this repo on the server (was $TARGETDIR, with the repo at $TARGETDIR/latency)
TARGET=$3
DPORT=$4
N=$5
IODEPTH=$6
SIZE=$7
PIN=$8
PERMUTE=$9
THREADS_PER_CORE=${10}

mkdir -p "$REPO/temp"

# Split the comma-separated core list into positional parameters.
OLD_IFS=$IFS
IFS=,
set -- $TASKSET_LIST
IFS=$OLD_IFS

# The client uses 0-based indexing for port calculation, so idx starts at 0.
idx=0
for core in "$@"; do
    port=$((DPORT + idx))

    threads=$THREADS_PER_CORE
    log="$REPO/temp/server_${idx}_core${core}_port${port}.log"

    echo "[server] i=$idx core=$core port=$port threads=$threads" >> "$log"
    echo "[server] i=$idx core=$core port=$port threads=$threads"

    sudo taskset -c "$core" nice -n -20 \
        "$REPO/application/latency_server_cores" \
        --ip "$TARGET" --port "$port" --count "$threads" \
        --iodepth "$IODEPTH" --flowsize "$SIZE" \
        --pin "$PIN" --permute "$PERMUTE" --sc "$core" \
        >> "$log" 2>&1 &

    idx=$((idx + 1))
done

wait
