#!/usr/bin/env bash
# shellcheck disable=SC2016  # documentation assertions are literal Markdown

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"

public_variables="$({
  sed -n 's/.*${\(VIRTDEV_[A-Z0-9_]*\):=.*/\1/p' \
    "${repository}"/bin/virtdev-* "${repository}"/lib/virtdev/*
  printf '%s\n' VIRTDEV_DNS VIRTDEV_INVENTORY VIRTDEV_ISO_PROFILE \
    VIRTDEV_LOCK_DIRECTORY VIRTDEV_PACKAGES VIRTDEV_SCRIPT \
    VIRTDEV_TRANSFER_MAX_TRANSACTION_BYTES
} | LC_ALL=C sort -u)"

for document in README.md DESIGN.md; do
  while IFS= read -r variable; do
    printf -v row "| \`%s\`" "${variable}"
    row_count="$(grep -Fc -- "${row}" "${repository}/${document}")"
    if (( row_count != 1 )); then
      printf '%s must contain one table row for %s; found %d\n' \
        "${document}" "${variable}" "${row_count}" >&2
      exit 1
    fi
  done <<< "${public_variables}"
done

for document in README.md DESIGN.md; do
  lock_row="$(grep -F '| `VIRTDEV_LOCK_DIRECTORY`' \
    "${repository}/${document}")"
  for contract in XDG_RUNTIME_DIR XDG_STATE_HOME 'all lock domains'; do
    if [[ "${lock_row}" != *"${contract}"* ]]; then
      printf '%s does not document VIRTDEV_LOCK_DIRECTORY %s\n' \
        "${document}" "${contract}" >&2
      exit 1
    fi
  done
done

for document in README.md DESIGN.md; do
  diagnostic_row="$(grep -F '| `VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES`' \
    "${repository}/${document}")"
  for contract in 'untrusted subprocess diagnostics' 'guest transport' \
    'host tar/rsync'; do
    if [[ "${diagnostic_row}" != *"${contract}"* ]]; then
      printf '%s does not document diagnostic limit purpose %s\n' \
        "${document}" "${contract}" >&2
      exit 1
    fi
  done

  allocated_row="$(grep -F '| `VIRTDEV_TRANSFER_MAX_ALLOCATED_BYTES`' \
    "${repository}/${document}")"
  transaction_row="$(grep -F '| `VIRTDEV_TRANSFER_MAX_TRANSACTION_BYTES`' \
    "${repository}/${document}")"
  if [[ "${allocated_row}" != *10737418240* \
      || "${allocated_row}" != *'per materialized tree'* ]]; then
    printf '%s does not document the per-tree transfer allocation limit\n' \
      "${document}" >&2
    exit 1
  fi
  if [[ "${transaction_row}" != *53687091200* \
      || "${transaction_row}" != *'aggregate host transaction cap'* ]]; then
    printf '%s does not document the aggregate transfer transaction limit\n' \
      "${document}" >&2
    exit 1
  fi
done

while IFS='|' read -r variable accepted_range; do
  for document in README.md DESIGN.md; do
    row="$(grep -F "| \`${variable}\`" "${repository}/${document}")"
    if [[ "${row}" != *"${accepted_range}"* ]]; then
      printf '%s does not document %s range %s\n' \
        "${document}" "${variable}" "${accepted_range}" >&2
      exit 1
    fi
  done
done <<'LIMITS'
VIRTDEV_SYSTEM_DISK_SIZE|qemu-img
VIRTDEV_HOME_DISK_SIZE|qemu-img
VIRTDEV_VM_MEMORY|Positive integer
VIRTDEV_VM_CPUS|Positive integer
VIRTDEV_INSTALL_SOCKET_TIMEOUT|1..86400
VIRTDEV_INSTALL_PROGRESS_TIMEOUT|1..86400
VIRTDEV_INSTALL_SHUTDOWN_TIMEOUT|1..86400
VIRTDEV_STOP_TIMEOUT|1..86400
VIRTDEV_WAIT_TIMEOUT|1..86400
VIRTDEV_TRIGGER_TIMEOUT|1..3600
VIRTDEV_TRIGGER_KILL_AFTER|1..60
VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES|1..1048576
VIRTDEV_MAINTENANCE_HOOK_TIMEOUT|1..86400
VIRTDEV_MAINTENANCE_HOOK_KILL_AFTER|1..60
VIRTDEV_MAINTENANCE_HOOK_OUTPUT_MAX_BYTES|1..67108864
VIRTDEV_BACKUP_MAX_BYTES|1..1099511627776
VIRTDEV_BACKUP_MAX_ENTRIES|1..10000000
VIRTDEV_BACKUP_TIMEOUT|1..86400
VIRTDEV_BACKUP_KILL_AFTER|1..60
VIRTDEV_RESTORE_MAX_BYTES|1..1099511627776
VIRTDEV_RESTORE_MAX_ENTRIES|1..10000000
VIRTDEV_RESTORE_TIMEOUT|1..86400
VIRTDEV_RESTORE_KILL_AFTER|1..60
VIRTDEV_TRANSFER_MAX_BYTES|1..1099511627776
VIRTDEV_TRANSFER_MAX_ALLOCATED_BYTES|1..2199023255552
VIRTDEV_TRANSFER_MAX_TRANSACTION_BYTES|1..10995116277760
VIRTDEV_TRANSFER_MAX_ENTRIES|1..10000000
VIRTDEV_TRANSFER_TIMEOUT|1..86400
VIRTDEV_TRANSFER_KILL_AFTER|1..60
VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES|1..1048576
LIMITS

printf 'ok - public environment variables and resource limits are documented\n'
