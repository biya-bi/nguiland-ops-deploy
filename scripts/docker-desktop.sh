#!/usr/bin/env bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"

docker_desktop::configure_registry() {
  local node_container="${NGUILAND_DOCKER_DESKTOP_NODE:-desktop-control-plane}"
  if ! kubectl get node "${node_container}" >/dev/null 2>&1; then
    logger::error "Docker Desktop node '${node_container}' is not available in the current Kubernetes context."
    return 1
  fi

  if ! docker container inspect "${node_container}" >/dev/null 2>&1; then
    logger::error "Docker Desktop node container '${node_container}' is not available."
    return 1
  fi

  if ! docker exec "${node_container}" sh -ec '
    config_path="/etc/containerd/certs.d/host.docker.internal:80/hosts.toml"
    expected="server = \"http://host.docker.internal:80\""

    if [ -f "$config_path" ]; then
      current=$(cat "$config_path")
      if [ "$current" != "$expected" ]; then
        printf "Unexpected existing config at %s; refusing to overwrite it.\\n" "$config_path" >&2
        exit 1
      fi
    else
      mkdir -p "$(dirname "$config_path")"
      printf "%s\\n" "$expected" > "$config_path"
    fi
  '; then
    logger::error "Failed to configure the Docker Desktop containerd registry route."
    return 1
  fi

  logger::info "Configured Docker Desktop image pulls to bypass its global registry mirror for Artifactory."
}

docker_desktop::configure() {
  docker_desktop::configure_registry
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  docker_desktop::configure
fi
