#!/usr/bin/env bash
# Copyright Broadcom, Inc. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0
#
# Install a chart into the cluster pointed at by $KUBECONFIG (a k3s node in CI)
# and assert that every workload it creates actually becomes healthy.
#
# Usage: verify-chart-install.sh <chart>
#
# Optional, per chart, committed next to the workflow:
#   .github/chart-verify/<chart>.yaml   extra `-f` values (resource limits,
#                                       disabling heavyweight subcharts, ...)
#   .github/chart-verify/<chart>.skip   presence marks the chart as not
#                                       verifiable on a single CI node; the
#                                       install is skipped but `helm template`
#                                       still has to render cleanly
#
# Environment:
#   NAMESPACE          target namespace                (default: chart-verify)
#   RELEASE            helm release name               (default: <chart>)
#   WAIT_TIMEOUT       per-rollout timeout             (default: 900s)
#   PULL_SECRET_NAME   image pull secret to inject     (default: none)

set -euo pipefail

CHART="${1:?usage: verify-chart-install.sh <chart>}"
CHART_DIR="bitmoa/${CHART}"
NAMESPACE="${NAMESPACE:-chart-verify}"
RELEASE="${RELEASE:-${CHART}}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900s}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-}"
OVERRIDES=".github/chart-verify/${CHART}.yaml"
SKIP_MARKER=".github/chart-verify/${CHART}.skip"

[[ -d "$CHART_DIR" ]] || { echo "ERROR: ${CHART_DIR} not found"; exit 1; }

HELM_ARGS=(--namespace "$NAMESPACE")
if [[ -f "$OVERRIDES" ]]; then
  echo "Using extra values from ${OVERRIDES}"
  HELM_ARGS+=(-f "$OVERRIDES")
fi
if [[ -n "$PULL_SECRET_NAME" ]]; then
  HELM_ARGS+=(--set "global.imagePullSecrets[0]=${PULL_SECRET_NAME}")
fi

dump_diagnostics() {
  echo "::group::Diagnostics for ${RELEASE} in ${NAMESPACE}"
  kubectl get all -n "$NAMESPACE" -o wide || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 50 || true
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    echo "--- describe ${pod}"
    kubectl describe pod -n "$NAMESPACE" "$pod" || true
    echo "--- logs ${pod} (all containers, previous+current)"
    kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=100 || true
    kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=100 --previous 2>/dev/null || true
  done < <(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null | sed 's|pod/||')
  echo "::endgroup::"
}
trap 'rc=$?; [[ $rc -ne 0 ]] && dump_diagnostics; exit $rc' EXIT

# --- dependencies ------------------------------------------------------------
if grep -q '^dependencies:' "${CHART_DIR}/Chart.yaml"; then
  helm repo add bitmoa https://charts.bitmoa.net/bitmoa/ >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm dependency update "$CHART_DIR"
fi

# --- render always, even for skipped charts ----------------------------------
echo "==> helm lint / template ${CHART}"
helm lint "$CHART_DIR" "${HELM_ARGS[@]}"
helm template "$RELEASE" "$CHART_DIR" "${HELM_ARGS[@]}" > /tmp/"${CHART}"-rendered.yaml
echo "Rendered $(grep -c '^---' /tmp/"${CHART}"-rendered.yaml || true) manifests"

if [[ -f "$SKIP_MARKER" ]]; then
  echo "==> ${SKIP_MARKER} present - skipping cluster install for ${CHART}"
  echo "    reason: $(cat "$SKIP_MARKER")"
  trap - EXIT
  exit 0
fi

# --- install -----------------------------------------------------------------
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> helm install ${RELEASE}"
# --wait is deliberately NOT used here: it hides which workload failed. The
# explicit rollout checks below give a precise failure and useful logs.
helm upgrade --install "$RELEASE" "$CHART_DIR" "${HELM_ARGS[@]}" \
  --create-namespace \
  --timeout "$WAIT_TIMEOUT"

# --- wait for every workload -------------------------------------------------
echo "==> waiting for rollouts (timeout ${WAIT_TIMEOUT})"
for kind in deployment statefulset daemonset; do
  while IFS= read -r res; do
    [[ -n "$res" ]] || continue
    echo "--- rollout status ${res}"
    kubectl rollout status -n "$NAMESPACE" "$res" --timeout="$WAIT_TIMEOUT"
  done < <(kubectl get "$kind" -n "$NAMESPACE" -o name 2>/dev/null)
done

echo "==> waiting for all pods to be Ready"
kubectl wait --for=condition=Ready pods --all -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT"

# --- assert nothing is quietly restarting ------------------------------------
echo "==> checking container states"
bad=0
while read -r pod phase restarts; do
  [[ -n "$pod" ]] || continue
  if [[ "$phase" != "Running" && "$phase" != "Succeeded" ]]; then
    echo "FAIL: pod ${pod} is in phase ${phase}"
    bad=1
  fi
  if [[ "${restarts:-0}" -gt 0 ]]; then
    echo "FAIL: pod ${pod} restarted ${restarts} time(s)"
    bad=1
  fi
done < <(kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}')
[[ "$bad" -eq 0 ]] || exit 1

# --- chart's own tests, when it ships any ------------------------------------
if grep -rqs 'helm.sh/hook: *test' "${CHART_DIR}/templates"; then
  echo "==> helm test ${RELEASE}"
  helm test "$RELEASE" --namespace "$NAMESPACE" --timeout "$WAIT_TIMEOUT" --logs
else
  echo "==> chart ships no helm tests, skipping 'helm test'"
fi

echo "==> ${CHART} verified successfully"
trap - EXIT
helm uninstall "$RELEASE" --namespace "$NAMESPACE" --wait --timeout 300s || true
kubectl delete namespace "$NAMESPACE" --wait=false || true
