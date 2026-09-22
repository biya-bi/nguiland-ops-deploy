#!/usr/bin/env bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"
. "${scripts_dir}/wait-k8s-resource.sh"

wait_for_gitrepository_exists() {
  wait_for_resource "${1}" "gitrepository" "${2}" "exists" "${3:-10m}"
}

wait_for_gitrepository() {
  wait_for_resource "${1}" "gitrepository" "${2}" "condition=Ready" "${3:-5m}"
}

wait_for_helmrepository_exists() {
  wait_for_resource "${1}" "helmrepository" "${2}" "exists" "${3:-10m}"
}

wait_for_helmrelease_exists() {
  wait_for_resource "${1}" "helmrelease" "${2}" "exists" "${3:-10m}"
}

wait_for_helmrelease() {
  wait_for_resource "${1}" "helmrelease" "${2}" "condition=Ready" "${3:-5m}"
}

wait_for_kustomization_exists() {
  wait_for_resource "${1}" "kustomization" "${2}" "exists" "${3:-10m}"
}

wait_for_kustomization() {
  wait_for_resource "${1}" "kustomization" "${2}" "condition=Ready" "${3:-5m}"
}

reconcile_resource() {
  local namespace="${1}"
  local resource_type="${2}"
  local resource_name="${3}"

  log_info "Triggering reconciliation signal for ${resource_type}/${resource_name} in namespace ${namespace}"
  kubectl patch "${resource_type}" "${resource_name}" -n "${namespace}" --type merge -p "{\"metadata\":{\"annotations\":{\"reconcile.toolkit.fluxcd.io/requestedAt\":\"$(date +%s)\"}}}" >/dev/null
}

toggle_resource_suspension() {
  local namespace="${1}"
  local resource_type="${2}"
  local resource_name="${3}"
  local suspend="${4}"

  kubectl patch "${resource_type}" "${resource_name}" -n "${namespace}" --type merge -p "{\"spec\":{\"suspend\":${suspend}}}" >/dev/null
}

reconcile_helm_release() {
  reconcile_resource "${1}" "helmrelease" "${2}"
}

reconcile_helm_repository() {
  reconcile_resource "${1}" "helmrepository" "${2}"
}

reconcile_git_repository() {
  reconcile_resource "${1}" "gitrepository" "${2}"
}

reconcile_kustomization() {
  reconcile_resource "${1}" "kustomization" "${2}"
}

ensure_git_repository_ready() {
  local namespace="${1}"
  local repo_name="${2}"
  local timeout="${3:-10m}"

  wait_for_gitrepository_exists "${namespace}" "${repo_name}" "${timeout}"
  reconcile_git_repository "${namespace}" "${repo_name}"
  wait_for_gitrepository "${namespace}" "${repo_name}" "${timeout}"
}

ensure_helm_release_ready() {
  local namespace="${1}"
  local release_name="${2}"
  local timeout="${3:-10m}"
  local optional="${4:-false}"

  if [[ "${optional}" == "true" ]]; then
    if ! kubectl get helmrelease "${release_name}" -n "${namespace}" >/dev/null 2>&1; then
      # If the release is optional and not found immediately, give Flux a short 
      # window to materialize the resource before assuming it is excluded.
      if ! wait_for_helmrelease_exists "${namespace}" "${release_name}" "1m"; then
        log_info "Optional HelmRelease ${release_name} was not discovered. Skipping..."
        return 0
      fi
    fi
  else
    wait_for_helmrelease_exists "${namespace}" "${release_name}" "${timeout}"
  fi

  reconcile_helm_release "${namespace}" "${release_name}"
  wait_for_helmrelease "${namespace}" "${release_name}" "${timeout}"
}

ensure_kustomization_ready() {
  local namespace="${1}"
  local kustomization_name="${2}"
  local timeout="${3:-10m}"
  local optional="${4:-false}"

  if [[ "${timeout}" == "true" || "${timeout}" == "false" ]]; then
    optional="${timeout}"
    timeout="10m"
  fi

  if [[ "${optional}" == "true" ]]; then
    if ! kubectl get kustomization "${kustomization_name}" -n "${namespace}" >/dev/null 2>&1; then
      # If the Kustomization is optional and not found immediately, give Flux a short
      # window to materialize the resource before assuming it is excluded.
      if ! wait_for_kustomization_exists "${namespace}" "${kustomization_name}" "1m"; then
        log_info "Optional Kustomization ${kustomization_name} was not discovered. Skipping..."
        return 0
      fi
    fi
  else
    wait_for_kustomization_exists "${namespace}" "${kustomization_name}" "${timeout}"
  fi

  reconcile_kustomization "${namespace}" "${kustomization_name}"
  wait_for_kustomization "${namespace}" "${kustomization_name}" "${timeout}"
}

suspend_helmreleases() {
  local namespace="${1}"
  shift

  # If no arguments are left, exit early
  [[ $# -eq 0 ]] && return 0

  local release_name
  local suspended
  for release_name in "$@"; do
    # Guard against empty strings/whitespace passed as arguments
    [[ -z "${release_name// /}" ]] && continue

    wait_for_helmrelease_exists "${namespace}" "${release_name}" "10m"

    suspended=$(kubectl get helmrelease "${release_name}" -n "${namespace}" -o jsonpath='{.spec.suspend}')
    if [[ "${suspended}" == "true" ]]; then
      log_info "HelmRelease ${release_name} is already suspended. Skipping..."
      continue
    fi

    log_info "Suspending HelmRelease ${release_name} in namespace ${namespace}"
    toggle_resource_suspension "${namespace}" "helmrelease" "${release_name}" "true"
  done
}

resume_helmreleases() {
  local namespace="${1}"
  shift

  # If no arguments are left, exit early
  [[ $# -eq 0 ]] && return 0

  local release_name
  local suspended
  for release_name in "$@"; do
    # Guard against empty strings/whitespace passed as arguments
    [[ -z "${release_name// /}" ]] && continue

    suspended=$(kubectl get helmrelease "${release_name}" -n "${namespace}" -o jsonpath='{.spec.suspend}')
    if [[ "${suspended}" != "true" ]]; then
      log_info "HelmRelease ${release_name} is already resumed. Skipping..."
      continue
    fi

    log_info "Resuming HelmRelease ${release_name} in namespace ${namespace}"
    toggle_resource_suspension "${namespace}" "helmrelease" "${release_name}" "false"
    reconcile_helm_release "${namespace}" "${release_name}"
  done
}

get_dependent_helmreleases() {
  local namespace="${1}"
  shift

  kubectl get helmrelease -n "${namespace}" -o json | jq -r --arg target_ns "${namespace}" '
    .items[] |
    select(
      .spec.dependsOn // [] |
      any(
        .name == $ARGS.positional[] and 
        ((.namespace == null) or (.namespace == $target_ns))
      )
    ) |
    .metadata.name
  ' --args "$@"
}
