#!/usr/bin/env bash

set -euo pipefail

run::yes_or_no() {
  local question="${1}"

  while true; do
    read -p "${question} [y/n] " response
    case "${response}" in
      [yY] ) echo yes;
        break;;
      [nN] ) echo no;
        exit;;
    esac
  done
}

run::get_sops_age_private_key() {
  local sops_age_key_file="${1}"

  local regex='#\spublic\skey:\s.\+'

  echo $(grep -e "${regex}" "${sops_age_key_file}" -A 1 | grep -v -e "${regex}")
}

run::create_namespace() {
  local namespace="${1}"

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
}

run::create_age_key_secret() {
  local namespace="${1}"
  local secret_name="${2}"
  local sops_age_private_key="${3}"

  kubectl create secret generic "${secret_name}" --namespace="${namespace}" --from-literal=identity.agekey="${sops_age_private_key}" --dry-run=client -o yaml | kubectl apply -f -
}

run::create_sops_age_secret() {
  local namespace="${1}"
  local sops_age_key_file="${2}"

  if [ -f "${sops_age_key_file}" ]; then
    local question
    question=$(printf "The '%s' environment variable points to the '%s' file. \nDo you want to use the later file for the deployment?\n" "SOPS_AGE_KEY_FILE" "${sops_age_key_file}")
    local response
    response=$(run::yes_or_no "${question}")
    if [ "${response}" == "yes" ]; then
      run::create_namespace "${namespace}"

      local sops_age_private_key
      sops_age_private_key=$(run::get_sops_age_private_key "${sops_age_key_file}")

      run::create_age_key_secret "${namespace}" "sops-age" "${sops_age_private_key}"
    fi
  fi
}

run::bootstrap_flux() {
  local namespace="${1}"
  local owner="${2}"
  local repository="${3}"
  local branch="${4}"
  local cluster="${5}"

  flux bootstrap github \
    --namespace="${namespace}" \
    --components-extra=image-reflector-controller,image-automation-controller \
    --token-auth \
    --owner="${owner}" \
    --repository="${repository}" \
    --branch="${branch}" \
    --path=clusters/"${cluster}" \
    --personal
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cluster="${1}"
  branch="${2}"

  flux_namespace="flux-system"
  target_namespace="${cluster}"
  sops_age_namespace="${target_namespace}"
  owner="biya-bi"
  repository="nguiland-ops-flux"

  sops_age_key_file=$(echo "${SOPS_AGE_KEY_FILE:-}" | xargs)

  run::create_sops_age_secret "${sops_age_namespace}" "${sops_age_key_file}"
  run::bootstrap_flux "${flux_namespace}" "${owner}" "${repository}" "${branch}" "${cluster}"

  # Invoke deploy.sh after run::bootstrap_flux completes.
  # The deploy.sh script is expected to live alongside this start script.
  scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "${scripts_dir}/deploy.sh" "${cluster}" "${target_namespace}"
fi