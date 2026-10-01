#!/usr/bin/env bash

set -euo pipefail

# Portable yq in-place edit function to handle both mikefarah/yq (Go) and kislyuk/yq (Python)
yq::edit() {
  local expression="$1"
  local file="$2"

  if yq --version 2>&1 | grep -q "mikefarah"; then
    yq -i "${expression}" "${file}"
  else
    yq -yi "${expression}" "${file}"
  fi
}

# Portable yq read function to handle both mikefarah/yq (Go) and kislyuk/yq (Python)
yq::read() {
  local expression="$1"
  local file="$2"

  if yq --version 2>&1 | grep -q "mikefarah"; then
    yq eval "${expression}" "${file}"
  else
    yq -r "${expression}" "${file}"
  fi
}
