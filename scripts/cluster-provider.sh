#!/usr/bin/env bash

cluster_provider::configure() {
  local environment="${1:-}"
  local normalized_environment
  local provider

  normalized_environment=$(echo "${environment}" | tr '[:upper:]' '[:lower:]' | xargs)
  provider=$(echo "${NGUILAND_LOCAL_CLUSTER_PROVIDER:-docker_desktop}" | tr '[:upper:]' '[:lower:]' | xargs)

  if [[ "${normalized_environment}" != "local" ]]; then
    return 0
  fi

  case "${provider}" in
    docker_desktop)
      local scripts_dir
      scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      . "${scripts_dir}/docker-desktop-registry.sh"
      desktop_registry::configure
      ;;
  esac
}
