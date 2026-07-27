#!/usr/bin/env bash
# Copyright Broadcom, Inc. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0
#
# Print (one per line) the name of every top-level chart under bitmoa/ whose
# values.yaml references the given container image repository.
#
# Usage: find-charts-for-image.sh <image-name>
#   e.g. find-charts-for-image.sh argo-workflow-controller
#
# Only `bitmoa/<chart>/values.yaml` is inspected on purpose: images referenced
# from `bitmoa/<chart>/charts/*` come from packaged dependencies and are bumped
# when the dependency chart itself is released.

set -euo pipefail

IMAGE="${1:?usage: find-charts-for-image.sh <image-name>}"
ORG="${IMAGE_ORG:-bitmoa}"

# Anchored match so that e.g. `argo-workflow-cli` never matches
# `argo-workflow-cli-something`. Quotes around the value are optional.
pattern="^[[:space:]]*repository:[[:space:]]*[\"']?${ORG}/${IMAGE}[\"']?[[:space:]]*$"

while IFS= read -r values_file; do
  chart="$(basename "$(dirname "$values_file")")"
  if grep -qE "$pattern" "$values_file"; then
    echo "$chart"
  fi
done < <(find bitmoa -mindepth 2 -maxdepth 2 -name values.yaml | sort) | sort -u
