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
. "${scripts_dir}/cluster-provider.sh"

deploy::cleanup_terminal() {
  printf '\033[?25h'
}
trap deploy::cleanup_terminal EXIT
trap 'exit 130' INT

deploy::reconcile_git_event_listener_chart() {
  local namespace="${1}"
  local release_name="git-event-listener"

  if ! kubectl get helmrelease "${release_name}" -n "${namespace}" >/dev/null 2>&1; then
    return 0
  fi

  local chart_name="${namespace}-${release_name}"
  flux::wait_for_helmchart_exists "${namespace}" "${chart_name}" "1m"
  flux::reconcile_helm_chart "${namespace}" "${chart_name}"
}

deploy::run() {
  local environment="${1:-}"
  local namespace="${2:-}"
  if [ -z "$environment" ]; then
    logger::error "environment is required"
    exit 1
  fi
  if [ -z "$namespace" ]; then
    logger::error "namespace is required"
    exit 1
  fi

  cluster_provider::configure "$environment"

  local port_forward_enabled=false
  if port_forward::enable "$environment"; then
    port_forward_enabled=true
  fi

  local jcr_release_name="artifactory-jcr"
  local oss_release_name="artifactory-oss"
  local postgres_release_name="postgres"
  local chart_git_repo_name="nguiland-ops-helm"
  local chart_repo_release_name="chart-repository"
  local chart_repo_source_name="chart-repository"
  local cicd_namespace="cicd"

  # The projects Kustomization creates the nguiland-ops-helm GitRepository,
  # so wait for it before waiting for that repository to become Ready.
  flux::ensure_kustomization_ready "${namespace}" "projects" "15m" "true"

  # Wait for the primary chart Git repository to be ready. This prevents
  # race conditions where HelmReleases are reconciled before Flux has
  # materialized the internal HelmChart proxy objects.
  flux::ensure_git_repository_ready "${cicd_namespace}" "${chart_git_repo_name}" "10m"

  local jcr_dependent_releases=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    jcr_dependent_releases+=("$line")
  done < <(flux::get_dependent_helmreleases "${namespace}" "${jcr_release_name}")

  if [[ ${#jcr_dependent_releases[@]} -gt 0 ]]; then
    flux::suspend_helmreleases "${namespace}" "${jcr_dependent_releases[@]}"
    trap "flux::resume_helmreleases ${namespace} ${jcr_dependent_releases[*]:-} || true; deploy::cleanup_terminal" EXIT
  fi

  # Ensure the internal chart repository is ready before the JCR registry (artifactory-jcr).
  # This is the primary source for the postgres and artifactory-jcr charts.
  flux::ensure_helm_release_ready "${namespace}" "${chart_repo_release_name}" "10m"

  # Force Flux to re-index the internal repository immediately so that
  # the postgres and JCR charts are discovered without waiting for the 5m poll interval.
  flux::reconcile_helm_repository "${namespace}" "${chart_repo_source_name}"

  # Ensure the PostgreSQL database is functionally ready if it is
  # deployed in this environment (local/int).
  flux::ensure_helm_release_ready "${namespace}" "${postgres_release_name}" "10m" "true"

  # Ensure the registry is functionally ready to receive image and OCI pushes.
  flux::ensure_helm_release_ready "${namespace}" "${jcr_release_name}" "15m"

  local docker_build_manifest_path="infra/docker/build.yaml"
  local oci_publish_manifest_path="infra/oci/publish.yaml"

  local pipeline_manifest_paths=()
  pipeline_manifest_paths+=("${docker_build_manifest_path}")
  pipeline_manifest_paths+=("${oci_publish_manifest_path}")

  local pipeline_name
  local relative_path
  for relative_path in "${pipeline_manifest_paths[@]}"; do
    pipeline_name=$(pipelines::get_pipeline_name "$relative_path")
    pipelines::wait_for_pipeline_exists "${cicd_namespace}" "${pipeline_name}" "15m"
  done

  # Before running the docker-publish pipeline, we need to start a port-forward
  # for artifactory-jcr so that the pipeline does not fail. This is particularly
  # important on environments (such as int) with Wireguard
  if [[ "$port_forward_enabled" == "true" ]]; then
    local port_forward_address="${NGUILAND_PORT_FORWARD_ADDRESS:-localhost}"
    port_forward::start_by_name "${port_forward_address}" "${jcr_release_name}" "${namespace}"
  fi

  # Ensure the tenant-resources kustomization is ready.
  flux::ensure_kustomization_ready "${namespace}" "tenant-resources"

  # Ensure the tekton-cicd kustomization is ready.
  flux::ensure_kustomization_ready "${namespace}" "tekton-cicd" "15m" "true"

  pipelines::run_docker_build_pipeline "${namespace}" "${cicd_namespace}" "${docker_build_manifest_path}"
  pipelines::run_oci_publish_pipeline "${namespace}" "${cicd_namespace}" "${oci_publish_manifest_path}"

  flux::wait_for_helmrepository_exists "${namespace}" "artifactory-oci" "10m"
  deploy::reconcile_git_event_listener_chart "${namespace}"

  # Resume dependent releases after artifactory-jcr is ready and the
  # helm-chart-oci-publish pipeline succeeded so that dependents that
  # pull their Helm charts from artifactory-jcr can pull them successfully.
  if [[ ${#jcr_dependent_releases[@]} -gt 0 ]]; then
    flux::resume_helmreleases "${namespace}" "${jcr_dependent_releases[@]}"
  fi

  # Ensure the OSS release is functionally ready if it is deployed in this
  # environment (local/int).
  flux::ensure_helm_release_ready "${namespace}" "${oss_release_name}" "15m" "true"

  # Ensure the git-event-listener release is ready.
  flux::ensure_helm_release_ready "${namespace}" "git-event-listener" "15m" "true"

  # Ensure the common kustomization is ready.
  flux::ensure_kustomization_ready "${namespace}" "common"

  # Ensure the nats kustomization is ready.
  flux::ensure_kustomization_ready "${namespace}" "nats" "15m" "true"

  # Ensure the git-events kustomization is ready.
  flux::ensure_kustomization_ready "${namespace}" "git-events" "15m" "true"

  if [[ "$port_forward_enabled" == "true" ]]; then
    "${scripts_dir}/port-forward.sh" "${namespace}"
  fi
}

# Direct-execution guard: only invoke deploy when this script is executed directly,
# not when it is sourced into another shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  deploy::run "$@"
fi
