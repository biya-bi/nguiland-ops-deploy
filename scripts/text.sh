#!/usr/bin/env bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "${scripts_dir}/logger.sh"

text::replace_placeholder() {
  local name=""
  local value=""
  local template_path=""
  local inplace="false"
  local opt

  # Reset OPTIND so getopts works if the function is called multiple times in one session
  local OPTIND=1
  local OPTARG
  while getopts "n:v:p:i" opt; do
    case "${opt}" in
      n) name="${OPTARG}" ;;
      v) value="${OPTARG}" ;;
      p) template_path="${OPTARG}" ;;
      i) inplace="true" ;;
      *) break ;;
    esac
  done

  if [[ -z "${name}" || -z "${value}" || -z "${template_path}" ]]; then
    logger::error "Missing required arguments.\nUsage: text::replace_placeholder -n <NAME> -v <VALUE> -p <PATH> [-i]"
    return 1
  fi

  if [[ ! -f "${template_path}" ]]; then
    logger::error "Template file not found: ${template_path}"
    return 1
  fi

  local output_path
  output_path=$(mktemp)

  local envsubst_filter='${'"${name}"'}'

  env "${name}=${value}" envsubst "${envsubst_filter}" < "${template_path}" > "${output_path}"

  if [[ "${inplace}" == "true" ]]; then
    cat "${output_path}" > "${template_path}"
    rm -f "${output_path}"
    logger::info "Placeholder ${name} replaced in-place in ${template_path}"
  else
    printf "%s\n" "${output_path}"
  fi
}
