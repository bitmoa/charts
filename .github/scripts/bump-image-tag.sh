#!/usr/bin/env bash
# Copyright Broadcom, Inc. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0
#
# Point a chart at a newly published container image.
#
# Usage: bump-image-tag.sh <chart> <image-name> <image-tag>
#   e.g. bump-image-tag.sh argo-workflows argo-workflow-controller 3.7.2-debian-12-r0
#
# It rewrites, in place:
#   * bitmoa/<chart>/values.yaml   - every `tag:` (and `digest:`) that belongs to
#                                    an image block whose `repository:` is
#                                    `<org>/<image-name>`
#   * bitmoa/<chart>/Chart.yaml    - the matching entry of `annotations.images`,
#                                    `appVersion` (only when it still matches the
#                                    image version being replaced) and a patch
#                                    bump of `version`
#
# Text editing (awk/sed) is used rather than `yq` so that the extensive comment
# blocks and `@param` metadata in values.yaml survive untouched.
#
# Outputs (appended to $GITHUB_OUTPUT when set):
#   changed          true|false
#   old_tag          previous image tag found in values.yaml
#   chart_version    new chart version
#   app_version      new appVersion (unchanged value if not bumped)

set -euo pipefail

CHART="${1:?usage: bump-image-tag.sh <chart> <image-name> <image-tag>}"
IMAGE="${2:?usage: bump-image-tag.sh <chart> <image-name> <image-tag>}"
NEW_TAG="${3:?usage: bump-image-tag.sh <chart> <image-name> <image-tag>}"
ORG="${IMAGE_ORG:-bitmoa}"
REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"

CHART_DIR="bitmoa/${CHART}"
VALUES="${CHART_DIR}/values.yaml"
CHART_YAML="${CHART_DIR}/Chart.yaml"

[[ -f "$VALUES" ]] || { echo "ERROR: ${VALUES} not found"; exit 1; }
[[ -f "$CHART_YAML" ]] || { echo "ERROR: ${CHART_YAML} not found"; exit 1; }

emit() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >> "$GITHUB_OUTPUT"; echo "$1=$2"; }

# The version part of a bitnami-style tag: 3.7.2-debian-12-r0 -> 3.7.2
tag_version() { echo "${1%%-*}"; }

# --- 1. current tag ----------------------------------------------------------
OLD_TAG="$(awk -v repo="${ORG}/${IMAGE}" '
  function indent(s,   n) { match(s, /^[ \t]*/); return RLENGTH }
  /^[[:space:]]*repository:[[:space:]]*/ {
    v = $0; sub(/^[[:space:]]*repository:[[:space:]]*/, "", v)
    gsub(/["'"'"']/, "", v); sub(/[[:space:]]*$/, "", v)
    if (v == repo) { track = 1; base = indent($0) } else { track = 0 }
    next
  }
  track && /^[[:space:]]*tag:[[:space:]]*/ && indent($0) == base {
    v = $0; sub(/^[[:space:]]*tag:[[:space:]]*/, "", v)
    gsub(/["'"'"']/, "", v); sub(/[[:space:]]*$/, "", v)
    print v; exit
  }
  track && /[^[:space:]]/ && indent($0) < base { track = 0 }
' "$VALUES")"

if [[ -z "$OLD_TAG" ]]; then
  echo "ERROR: no image block with repository '${ORG}/${IMAGE}' and a 'tag' key in ${VALUES}"
  exit 1
fi

echo "Chart ${CHART}: ${ORG}/${IMAGE} ${OLD_TAG} -> ${NEW_TAG}"

if [[ "$OLD_TAG" == "$NEW_TAG" ]]; then
  echo "Already up to date, nothing to do."
  emit changed false
  emit old_tag "$OLD_TAG"
  emit chart_version "$(sed -nE 's/^version:[[:space:]]*(.*)$/\1/p' "$CHART_YAML" | head -n1)"
  emit app_version "$(sed -nE 's/^appVersion:[[:space:]]*(.*)$/\1/p' "$CHART_YAML" | head -n1)"
  exit 0
fi

# --- 2. values.yaml ----------------------------------------------------------
awk -v repo="${ORG}/${IMAGE}" -v newtag="$NEW_TAG" '
  function indent(s,   n) { match(s, /^[ \t]*/); return RLENGTH }
  function pad(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
  /^[[:space:]]*repository:[[:space:]]*/ {
    v = $0; sub(/^[[:space:]]*repository:[[:space:]]*/, "", v)
    gsub(/["'"'"']/, "", v); sub(/[[:space:]]*$/, "", v)
    if (v == repo) { track = 1; base = indent($0) } else { track = 0 }
    print; next
  }
  track && /^[[:space:]]*tag:[[:space:]]*/ && indent($0) == base {
    print pad(base) "tag: " newtag; next
  }
  track && /^[[:space:]]*digest:[[:space:]]*/ && indent($0) == base {
    print pad(base) "digest: \"\""; next
  }
  { if (track && /[^[:space:]]/ && indent($0) < base) track = 0; print }
' "$VALUES" > "${VALUES}.tmp"
mv "${VALUES}.tmp" "$VALUES"

# --- 3. Chart.yaml: annotations.images --------------------------------------
# Entries look like:  - image: ghcr.io/bitmoa/argo-workflow-cli:3.7.1-debian-12-r0
esc_registry="${REGISTRY//./\\.}"
sed -i -E "s|(image:[[:space:]]*${esc_registry}/${ORG}/${IMAGE}):[^[:space:]]*|\1:${NEW_TAG}|" "$CHART_YAML"

# --- 4. Chart.yaml: appVersion ----------------------------------------------
# Only bumped when the chart's appVersion is still tracking the image version
# being replaced, so multi-image charts are not mis-labelled.
OLD_APP="$(sed -nE 's/^appVersion:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$CHART_YAML" | head -n1)"
NEW_APP="$OLD_APP"
if [[ "$OLD_APP" == "$(tag_version "$OLD_TAG")" ]]; then
  NEW_APP="$(tag_version "$NEW_TAG")"
  sed -i -E "s|^appVersion:.*$|appVersion: ${NEW_APP}|" "$CHART_YAML"
  echo "appVersion: ${OLD_APP} -> ${NEW_APP}"
else
  echo "appVersion left at ${OLD_APP} (does not track ${IMAGE})"
fi

# --- 5. Chart.yaml: chart version bump --------------------------------------
OLD_CHART_VERSION="$(sed -nE 's/^version:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$CHART_YAML" | head -n1)"
[[ "$OLD_CHART_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || {
  echo "ERROR: unsupported chart version '${OLD_CHART_VERSION}' in ${CHART_YAML}"
  exit 1
}
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
if [[ "$NEW_APP" != "$OLD_APP" ]]; then
  # New application version -> minor bump, matching the bitnami release policy.
  NEW_CHART_VERSION="${major}.$((minor + 1)).0"
else
  NEW_CHART_VERSION="${major}.${minor}.$((patch + 1))"
fi
sed -i -E "s|^version:.*$|version: ${NEW_CHART_VERSION}|" "$CHART_YAML"
echo "chart version: ${OLD_CHART_VERSION} -> ${NEW_CHART_VERSION}"

emit changed true
emit old_tag "$OLD_TAG"
emit chart_version "$NEW_CHART_VERSION"
emit app_version "$NEW_APP"
