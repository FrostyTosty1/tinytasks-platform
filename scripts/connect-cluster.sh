#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" \
    && pwd -P
)"

REPO_ROOT="$(
  cd -- "${SCRIPT_DIR}/.." \
    && pwd -P
)"

TERRAFORM_DIR="${REPO_ROOT}/terraform/hetzner"
SSH_KEY="${HOME}/.ssh/hetzner_devops_platform"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

RESET_HOST_KEYS=false

if [[ "${1:-}" == "--reset-host-keys" ]]; then
  RESET_HOST_KEYS=true
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--reset-host-keys]"
  exit 1
fi

for command in terraform jq gnome-terminal ssh ssh-keygen; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Error: required command '${command}' is not installed."
    exit 1
  fi
done

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "Error: no graphical desktop session detected."
  exit 1
fi

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "Error: Terraform directory not found: ${TERRAFORM_DIR}"
  exit 1
fi

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "Error: SSH private key not found: ${SSH_KEY}"
  exit 1
fi

CONTROL_PLANE_IP="$(
  terraform -chdir="${TERRAFORM_DIR}" \
    output -raw control_plane_public_ip
)"

WORKERS_JSON="$(
  terraform -chdir="${TERRAFORM_DIR}" \
    output -json worker_public_ips
)"

WORKER_COUNT="$(jq 'length' <<< "${WORKERS_JSON}")"

if [[ "${WORKER_COUNT}" -ne 2 ]]; then
  echo "Error: expected 2 worker IPs, found ${WORKER_COUNT}."
  exit 1
fi

WORKER_1_IP="$(jq -r '.[0]' <<< "${WORKERS_JSON}")"
WORKER_2_IP="$(jq -r '.[1]' <<< "${WORKERS_JSON}")"

if [[ "${RESET_HOST_KEYS}" == true ]]; then
  echo "Removing old SSH host keys for current Terraform IPs..."

  for ip in "${CONTROL_PLANE_IP}" "${WORKER_1_IP}" "${WORKER_2_IP}"; do
    ssh-keygen \
      -f "${KNOWN_HOSTS}" \
      -R "${ip}" \
      >/dev/null 2>&1 || true
  done
fi

open_ssh_terminal() {
  local title="$1"
  local ip="$2"
  local ssh_command

  printf -v ssh_command \
    'ssh -i %q root@%q' \
    "${SSH_KEY}" \
    "${ip}"

  gnome-terminal \
    --window \
    --title="${title}" \
    -- bash -lc \
    "${ssh_command}; status=\$?; echo; echo \"SSH session closed with status \$status.\"; exec bash"
}

open_ssh_terminal \
  "TinyTasks — Control Plane" \
  "${CONTROL_PLANE_IP}"

open_ssh_terminal \
  "TinyTasks — Worker 1" \
  "${WORKER_1_IP}"

open_ssh_terminal \
  "TinyTasks — Worker 2" \
  "${WORKER_2_IP}"

echo "Opened three SSH terminal windows."