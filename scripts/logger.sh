#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NO_COLOR='\033[0m'

logger::log() {
  local level_color="$1"
  local level_name="$2"
  local message="$3"
  local add_newline="${4:-true}"
  local timestamp
  timestamp=$(date +'%Y-%m-%dT%H:%M:%S')

  local nl=""
  [[ "${add_newline}" == "true" ]] && nl="\n"
  printf "${timestamp} ${level_color}${level_name}${NO_COLOR} ${message}${nl}"
}

logger::debug() {
  logger::log "${CYAN}" "DEBUG" "$1" "${2:-true}" >&2
}

logger::info() {
  logger::log "${GREEN}" "INFO" "$1" "${2:-true}"
}

logger::warn() {
  logger::log "${YELLOW}" "WARN" "$1" "${2:-true}" >&2
}

logger::error() {
  logger::log "${RED}" "ERROR" "$1" "${2:-true}" >&2
}

logger::rotate_log_file() {
  local log_file="$1"
  local backup_file="${2:-${log_file}.old}"

  cp "${log_file}" "${backup_file}"
  : > "${log_file}"

  echo "${backup_file}"
}
