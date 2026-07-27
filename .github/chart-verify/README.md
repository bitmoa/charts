# Chart verification overrides

Files here tune how `[CI/CD] Container Image Bump` verifies a chart on the
throwaway k3s cluster before the bump is committed to `main`.

| File | Effect |
| --- | --- |
| `<chart>.yaml` | Passed to `helm lint`/`template`/`upgrade --install` as an extra `-f`. Use it to shrink resource requests, disable heavyweight subcharts, or supply required values the chart has no default for. |
| `<chart>.skip` | Skips the cluster install for that chart. `helm lint` and `helm template` still have to succeed. Put the reason in the file — it is printed in the job log. |

Charts with no file here are installed with their default values.

Example — `postgresql.yaml`:

```yaml
primary:
  resourcesPreset: nano
auth:
  postgresPassword: verify-only-password
```

Example — `kube-prometheus.skip`:

```text
Requires more memory than a single GitHub-hosted runner provides.
```
