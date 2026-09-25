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

. "${scripts_dir}/yq.sh"
. "${scripts_dir}/pipelines.sh"
. "${scripts_dir}/port-forward.sh"
. "${scripts_dir}/flux.sh"
. "${scripts_dir}/logger.sh"

cleanup_terminal() {
  printf '\033[?25h'
}
trap cleanup_terminal EXIT
trap 'exit 130' INT

deploy() {
  local environment="${1:-}"
  local namespace="${2:-}"
  if [ -z "$environment" ]; then
    log_error "environment is required"
    exit 1
  fi
  if [ -z "$namespace" ]; then
    log_error "namespace is required"
    exit 1
  fi

  local port_forward_enabled=false
  if enable_port_forward "$environment"; then
    port_forward_enabled=true
  fi

  local jcr_release_name="artifactory-jcr"
  local oss_release_name="artifactory-oss"
  local postgres_release_name="postgres"
  local chart_git_repo_name="helm"
  local chart_repo_release_name="chart-repository"
  local chart_repo_source_name="chart-repository"

  # Wait for the primary chart Git repository to be ready. This prevents 
  # race conditions where HelmReleases are reconciled before Flux has 
  # materialized the internal HelmChart proxy objects.
  ensure_git_repository_ready "${namespace}" "${chart_git_repo_name}" "10m"

  local jcr_dependent_releases=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    jcr_dependent_releases+=("$line")
  done < <(get_dependent_helmreleases "${namespace}" "${jcr_release_name}")

  if [[ ${#jcr_dependent_releases[@]} -gt 0 ]]; then
    suspend_helmreleases "${namespace}" "${jcr_dependent_releases[@]}"
    trap "resume_helmreleases ${namespace} ${jcr_dependent_releases[*]:-} || true; cleanup_terminal" EXIT
  fi

  # Ensure the internal chart repository is ready before the JCR registry (artifactory-jcr).
  # This is the primary source for the postgres and artifactory-jcr charts.
  ensure_helm_release_ready "${namespace}" "${chart_repo_release_name}" "10m"

  # Force Flux to re-index the internal repository immediately so that
  # the postgres and JCR charts are discovered without waiting for the 5m poll interval.
  reconcile_helm_repository "${namespace}" "${chart_repo_source_name}"

  # Ensure the PostgreSQL database is functionally ready if it is
  # deployed in this environment (local/int).
  ensure_helm_release_ready "${namespace}" "${postgres_release_name}" "10m" "true"

  # Ensure the registry is functionally ready to receive image and OCI pushes.
  ensure_helm_release_ready "${namespace}" "${jcr_release_name}" "15m"

  local docker_build_manifest_path="infra/docker/build.yaml"
  local oci_publish_manifest_path="infra/oci/publish.yaml"

  local pipeline_manifest_paths=()
  pipeline_manifest_paths+=("${docker_build_manifest_path}")
  pipeline_manifest_paths+=("${oci_publish_manifest_path}")

  local pipeline_name
  local relative_path
  for relative_path in "${pipeline_manifest_paths[@]}"; do
    pipeline_name=$(get_pipeline_name "$relative_path")
    wait_for_pipeline_exists "${namespace}" "${pipeline_name}" "15m"
  done

  # Before running the docker-publish pipeline, we need to start a port-forward
  # for artifactory-jcr so that the pipeline does not fail. This is particularly
  # important on environments (such as int) with Wireguard
  if [[ "$port_forward_enabled" == "true" ]]; then
    local port_forward_address="${NGUILAND_PORT_FORWARD_ADDRESS:-localhost}"
    start_port_forward_by_name "${port_forward_address}" "${jcr_release_name}" "${namespace}"
  fi

  run_docker_build_pipeline "${namespace}" "${docker_build_manifest_path}"
  run_oci_publish_pipeline "${namespace}" "${oci_publish_manifest_path}"

  wait_for_helmrepository_exists "${namespace}" "artifactory-oci" "10m"

  # Resume dependent releases after artifactory-jcr is ready and the
  # helm-chart-oci-publish pipeline succeeded so that dependents that
  # pull their Helm charts from artifactory-jcr can pull them successfully.
  if [[ ${#jcr_dependent_releases[@]} -gt 0 ]]; then
    resume_helmreleases "${namespace}" "${jcr_dependent_releases[@]}"
  fi

  # Ensure the OSS release is functionally ready if it is deployed in this
  # environment (local/int).
  ensure_helm_release_ready "${namespace}" "${oss_release_name}" "15m" "true"

  # Ensure the git-event-listener release is ready.
  ensure_helm_release_ready "${namespace}" "git-event-listener" "15m" "true"

  # Ensure the common kustomization is ready.
  ensure_kustomization_ready "${namespace}" "common"

  # Ensure the nats kustomization is ready.
  ensure_kustomization_ready "${namespace}" "nats" "15m" "true"

  # Ensure the optional-streams kustomization is ready.
  ensure_kustomization_ready "${namespace}" "optional-streams" "15m" "true"

  # Ensure the optional-git-repositories kustomization is ready.
  ensure_kustomization_ready "${namespace}" "optional-git-repositories" "15m" "true"

  # Ensure the projects kustomization is ready.
  ensure_kustomization_ready "${namespace}" "projects" "15m" "true"

  if [[ "$port_forward_enabled" == "true" ]]; then
    "${scripts_dir}/port-forward.sh" "${namespace}"
  fi
}

# Direct-execution guard: only invoke deploy when this script is executed directly,
# not when it is sourced into another shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  deploy "$@"
fi
