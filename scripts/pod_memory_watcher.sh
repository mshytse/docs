#!/usr/bin/env bash
# Usage: ./pod_memory_watcher.sh <pod-name>
# Runs the loop inside the container (one exec). Shows current, anon, inactive_file, active_file in MB.
# Namespace: system-agent (set NAMESPACE env to override)

NAMESPACE="${NAMESPACE:-system-agent}"
POD_NAME="${1:?Usage: $0 <pod-name>}"

read -r -d '' INNER_SCRIPT << 'ENDINNER'
CURRENT_FILE=/sys/fs/cgroup/memory.current
STAT_FILE=/sys/fs/cgroup/memory.stat

while true; do
  current=0; anon=0; inactive_file=0; active_file=0
  [ -r "$CURRENT_FILE" ] && read -r current < "$CURRENT_FILE"
  if [ -r "$STAT_FILE" ]; then
    while read -r name value; do
      case "$name" in
        anon) anon=$value ;;
        inactive_file) inactive_file=$value ;;
        active_file) active_file=$value ;;
      esac
    done < "$STAT_FILE"
  fi

  current_mb=$(( current / 1048576 ))
  anon_mb=$(( anon / 1048576 ))
  inactive_mb=$(( inactive_file / 1048576 ))
  active_mb=$(( active_file / 1048576 ))

  printf "%s  current=%s MB  anon=%s MB  inactive_file=%s MB  active_file=%s MB\n" \
    "$(date '+%H:%M:%S' 2>/dev/null || echo -)" "$current_mb" "$anon_mb" "$inactive_mb" "$active_mb"
  sleep 1
done
ENDINNER

echo "Pod: $POD_NAME (ns: $NAMESPACE). Loop runs in container. Ctrl+C to stop."
echo ""

kubectl exec -it "$POD_NAME" -n "$NAMESPACE" -- /bin/sh -c "$INNER_SCRIPT"
