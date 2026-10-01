#!/usr/bin/env bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"

teardown::run() {
  logger::warn "This script will perform a destructive teardown of the Flux system and associated infrastructure."
  read -p "Are you sure you want to proceed? [y/N] " response
  if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    logger::info "Teardown aborted."
    return 0
  fi

  logger::info "--- 1. STOPPING THE FLUX GITOPS SYSTEM ---"
  flux uninstall --namespace flux-system --silent 2>/dev/null || true
  flux uninstall --namespace infra --silent 2>/dev/null || true
  flux uninstall --namespace kyverno --silent 2>/dev/null || true
  flux uninstall --namespace tekton-pipelines --silent 2>/dev/null || true

  logger::info "--- 2. KILLING CONTROLLER LOOPS (Scaling) ---"
  # Stop everything that could recreate webhooks or block deletions
  kubectl scale deployment --all --replicas=0 -A 2>/dev/null || true
  kubectl scale statefulset --all --replicas=0 -A 2>/dev/null || true
  kubectl scale daemonset --all --replicas=0 -A 2>/dev/null || true

  # Give the API a moment to register the shutdown
  sleep 2

  logger::info "--- 3. DISABLING CRD WEBHOOKS ---"
  # This stops the "connection refused" errors by telling the API server
  # to stop trying to use Kyverno's service to process its CRDs.
  kubectl get crds -o name 2>/dev/null | grep 'kyverno.io' | xargs -I {} kubectl patch {} --type='json' -p='[{"op": "replace", "path": "/spec/conversion/strategy", "value": "None"}]' 2>/dev/null || true

  logger::info "--- 4. PURGING ADMISSION GATEKEEPERS (Webhooks) ---"
  kubectl delete validatingwebhookconfigurations --all --force --grace-period=0 2>/dev/null || true
  kubectl delete mutatingwebhookconfigurations --all --force --grace-period=0 2>/dev/null || true

  logger::info "--- 5. NUKING DEFINITIONS AND NAMESPACES ---"
  # Delete CRDs now that their conversion webhooks are disabled
  kubectl get crds -o name 2>/dev/null | xargs -I {} kubectl delete {} --timeout=10s 2>/dev/null || true

  local namespaces="kyverno tekton-pipelines tekton-dashboard tekton-pipelines-resolvers infra flux-system"

  # Trigger namespace deletion
  kubectl delete ns ${namespaces} --ignore-not-found --wait=false || true

  logger::info "--- 6. FINALIZER CLEANUP (The Final Kill) ---"
  for ns in ${namespaces}; do
    kubectl patch ns "$ns" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  done

  logger::info "--- TEARDOWN COMPLETE ---"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  teardown::run "$@"
fi
