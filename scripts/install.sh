#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Environment Variables (Optional Overrides)
# -----------------------------------------------------------------------------
# NGUILAND_PORT_FORWARD_ADDRESS  : The IP or hostname to bind the tunnels to.
#                                  Defaults to 'localhost'.
#                                  Example: export NGUILAND_PORT_FORWARD_ADDRESS="10.0.0.2"
# -----------------------------------------------------------------------------

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"

install::port_forward_watchdog() {
  local port_forward_address="${1:-${NGUILAND_PORT_FORWARD_ADDRESS:-localhost}}"

  if ! command -v systemctl >/dev/null 2>&1; then
    logger::error "systemctl not found. This script is intended for systemd-based Linux systems."
    exit 1
  fi

  if ! command -v envsubst >/dev/null 2>&1; then
    logger::error "envsubst not found. Please install the 'gettext' package."
    exit 1
  fi

  export USER="$(whoami)"
  export NGUILAND_OPS_DEPLOY_DIR="$(cd "${scripts_dir}/.." && pwd)"
  export NGUILAND_PORT_FORWARD_ADDRESS="${port_forward_address}"

  logger::info "Installing port-forward service (binding to ${port_forward_address}) to /etc/systemd/system/..."

  local systemd_dir="${scripts_dir}/../on-premises/systemd"
  local port_forward_service="nguiland-port-forward.service"
  local source_service_file="${systemd_dir}/port-forward.service"
  local target_service_file="/etc/systemd/system/${port_forward_service}"

  envsubst < "${source_service_file}" | sudo tee "${target_service_file}" > /dev/null

  logger::info "Reloading systemd daemon..."
  sudo systemctl daemon-reload

  logger::info "Enabling and starting ${port_forward_service}..."
  sudo systemctl enable "${port_forward_service}"
  sudo systemctl start "${port_forward_service}"

  logger::info "Installation complete."
  logger::info "You can view logs with: journalctl -u "${port_forward_service}" -f"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install::port_forward_watchdog "$@"
fi
