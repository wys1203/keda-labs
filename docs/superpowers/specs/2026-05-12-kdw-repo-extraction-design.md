# kdw → standalone repo extraction — design

**Date:** 2026-05-12
**Status:** Approved (design phase); implementation plan TBD
**Owner:** wys1203

## Goal

Extract `kdw/` (keda-deprecation-webhook) from `keda-labs` into an independent,
publishable open-source repository. After extraction, `keda-labs` becomes a
consumer that installs the webhook via its published container image and Helm
chart, the same way any third-party user would.

## Non-goals

- Adding new features to the webhook itself.
- Setting up e2e CI, release-please, dependabot, CodeQL on day one
  (deferred — re-evaluate when external contributions arrive).
- Migrating `keda-labs`'s own Grafana stack to a sidecar-based dashboard
  provisioner. The lab keeps its current file-provisioner CM.

## End state — new repo

**Repo:** `github.com/wys1203/keda-deprecation-webhook`
**Module path:** `github.com/wys1203/keda-deprecation-webhook`
**License:** Apache-2.0
**Container registry:** `ghcr.io/wys1203/keda-deprecation-webhook`
**Helm repo:** `https://wys1203.github.io/keda-deprecation-webhook` (via
`chart-releaser` + GitHub Pages)
**Initial version:** `v0.1.0`

### Layout

```
keda-deprecation-webhook/
├── cmd/keda-deprecation-webhook/        # was kdw/cmd/
├── internal/{webhook,config,controller}/# was kdw/internal/
├── charts/keda-deprecation-webhook/     # NEW — from kdw/manifests/deploy/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl                 # standard Helm helpers
│       ├── namespace.yaml               # gated by `namespace.create`
│       ├── serviceaccount.yaml
│       ├── rbac.yaml                    # Role, RoleBinding, ClusterRole, ClusterRoleBinding
│       ├── configmap-rules.yaml         # deprecation rules (from values.rules)
│       ├── service.yaml
│       ├── deployment.yaml
│       ├── pdb.yaml                     # gated by `pdb.enabled`
│       ├── certificate.yaml             # Issuer + Certificate
│       ├── validatingwebhookconfiguration.yaml
│       └── configmap-dashboard.yaml     # gated by `dashboard.enabled`
├── examples/demo-deprecated/            # was kdw/demo/demo-deprecated/
├── dashboard.json                       # stays at repo root; chart references it
├── Dockerfile                           # was kdw/Dockerfile
├── go.mod  go.sum                       # module renamed
├── .github/workflows/{ci.yaml,release.yaml}
├── LICENSE  README.md  CONTRIBUTING.md  SECURITY.md
└── test/                                # was kdw/test/
```

### CI workflows

- `ci.yaml` — triggered on all PRs and pushes to `main`:
  - `go test ./...`
  - `go vet ./...`
  - `golangci-lint run`
  - `helm lint charts/keda-deprecation-webhook`
  - `docker build .` (no push)
- `release.yaml` — triggered on tags matching `v*`:
  - Build and push image to `ghcr.io/wys1203/keda-deprecation-webhook:<tag>`
    and `:latest`.
  - Run `chart-releaser` to package and publish the chart to GH Pages.

### Helm chart values (essentials)

These exist on day one. Everything else is added only when a user asks.

| Key | Default | Purpose |
|---|---|---|
| `image.repository` | `ghcr.io/wys1203/keda-deprecation-webhook` | |
| `image.tag` | chart `appVersion` | |
| `image.pullPolicy` | `IfNotPresent` | |
| `replicaCount` | `2` | matches current deployment.yaml |
| `namespace` | `keda-system` | the webhook lives next to KEDA |
| `webhook.failurePolicy` | `Ignore` | matches current VWC |
| `certificate.duration` | `8760h` | matches current cert-manager Certificate |
| `certificate.renewBefore` | `720h` | matches current cert-manager Certificate |
| `pdb.enabled` | `true` | gates PodDisruptionBudget |
| `pdb.maxUnavailable` | `1` | matches current PDB |
| `namespace.create` | `false` | when true, chart creates `keda-system` namespace |
| `rules` | see values.yaml | deprecation rules (mirrors current `configmap.yaml`) — `KEDA001` default `error`, no namespace overrides |
| `dashboard.enabled` | `false` | gates the dashboard CM (off by default; OSS users opt in) |

## End state — keda-labs

### Removed

- `kdw/` directory (entire subtree).
- Root build artifact `keda-deprecation-webhook` (~2.5 MB binary; should have
  been gitignored).

### Modified

- `scripts/lib.sh` — replace `KDW_DIR="${ROOT_DIR}/kdw"` with
  `KDW_VERSION="v0.1.0"`. (Lab pins a known-good kdw release.)
- `Makefile` — `kdw-image`, `kdw-install`, `kdw-verify`, `kdw-demo` targets
  become thin wrappers:
  - `kdw-install` → `helm repo add kdw https://wys1203.github.io/keda-deprecation-webhook && helm upgrade --install kdw kdw/keda-deprecation-webhook --version ${KDW_VERSION} -n keda-system --create-namespace --set 'rules[0].id=KEDA001,rules[0].defaultSeverity=error,rules[0].namespaceOverrides[0].names[0]=legacy-cpu,rules[0].namespaceOverrides[0].severity=warn'`
    (or a `lab/charts/values-kdw-lab.yaml` file checked in — the lab is the
    "warn-mode demo" use case from `kdw/manifests/deploy/configmap.yaml`.)
  - `kdw-verify` → `kubectl rollout status deploy/keda-deprecation-webhook -n keda-system --timeout=120s && kubectl get validatingwebhookconfiguration keda-deprecation-webhook`
  - `kdw-demo` → `kubectl apply -f https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}/examples/demo-deprecated/`
  - `kdw-image` is removed (no longer relevant — image comes from GHCR).
- `scripts/up.sh` — replace direct `source kdw/scripts/install-webhook.sh`
  with `make kdw-install`.
- `lab/scripts/install-grafana.sh` — replace
  `--from-file=keda-deprecations.json="${KDW_DIR}/dashboard.json"` with a
  fetch from raw GitHub at the pinned version:
  `curl -fsSL https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}/dashboard.json -o /tmp/keda-deprecations.json`
  then `--from-file=keda-deprecations.json=/tmp/keda-deprecations.json`.
  Grafana's file-provisioner remains unchanged.
- `README.md`, `docs/keda-deprecation-webhook-zh-TW.md`, `docs/lab-overview.md`,
  `docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md`,
  `docs/superpowers/plans/2026-05-09-keda-deprecation-webhook.md` — update
  install instructions and URLs to point at the new repo.

### Added

None.

## Migration mechanics

### Step 1 — extract history into a working tree for the new repo

```sh
git clone <keda-labs> /tmp/kdw-extract
cd /tmp/kdw-extract
git filter-repo --subdirectory-filter kdw
```

After this, all commits that touched `kdw/` are preserved (with new SHAs),
the directory contents are at the repo root, and history before kdw's
introduction is dropped. `git log` will show authorship/dates intact.

### Step 2 — shape the new repo content

In `/tmp/kdw-extract`:

1. Rewrite module path in `go.mod` from
   `github.com/wys1203/keda-labs/kdw` to
   `github.com/wys1203/keda-deprecation-webhook`.
2. Rewrite imports:
   `grep -rl github.com/wys1203/keda-labs/kdw . | xargs sed -i '' 's|github.com/wys1203/keda-labs/kdw|github.com/wys1203/keda-deprecation-webhook|g'`
3. Restructure:
   - Move `manifests/deploy/*.yaml` into
     `charts/keda-deprecation-webhook/templates/` and templatize against the
     values listed above.
   - Rename `demo/` → `examples/`.
4. Add OSS housekeeping files: `LICENSE` (Apache-2.0), `README.md` (install
   instructions, what it does, link back to keda-labs as reference lab),
   `CONTRIBUTING.md`, `SECURITY.md` (minimal).
5. Add CI: `.github/workflows/ci.yaml` and `.github/workflows/release.yaml`.
6. Add chart-releaser config (`.github/cr.yaml` or workflow inline).
7. Local verification gate (must all pass before pushing):
   - `go build ./...`
   - `go vet ./...`
   - `go test ./...`
   - `helm lint charts/keda-deprecation-webhook`
   - `helm template charts/keda-deprecation-webhook` produces output
     equivalent to the current `kdw/manifests/deploy/*.yaml` for the default
     values (chart-vs-manifests diff documented in PR description).
   - `docker build -t kdw:local .` succeeds.
8. `gh repo create wys1203/keda-deprecation-webhook --public --push`.

### Step 3 — first release

1. Test the release workflow with a pre-release tag: `git tag v0.0.0-rc1 && git push --tags`. Confirm image lands in GHCR and chart-releaser publishes
   to GH Pages. Resolve any workflow errors.
2. Tag `v0.1.0` and push. Verify:
   - `ghcr.io/wys1203/keda-deprecation-webhook:v0.1.0` pullable.
   - `helm repo add kdw https://wys1203.github.io/keda-deprecation-webhook && helm search repo kdw` shows `keda-deprecation-webhook 0.1.0`.

### Step 4 — keda-labs cleanup PR

Single PR with **two commits** to keep rollback cheap:

- **Commit 1** — _Switch to consuming the chart_: modify `scripts/lib.sh`,
  `Makefile`, `scripts/up.sh`, `lab/scripts/install-grafana.sh`, `README.md`,
  and docs as listed under "Modified" above. **Do not delete `kdw/` yet.**
- **Commit 2** — _Remove vendored kdw_: delete `kdw/` and the root
  `keda-deprecation-webhook` binary.

Commit message for the PR's merge commit:
`feat(kdw): extract to github.com/wys1203/keda-deprecation-webhook, consume v0.1.0`.

## Verification / success criteria

### New repo (gate before announcing)

- `go test ./...` green.
- `go vet ./... && golangci-lint run` green.
- `helm lint charts/keda-deprecation-webhook` green.
- `docker build .` succeeds.
- On a fresh `kind` cluster: install cert-manager, install KEDA,
  `helm install kdw kdw/keda-deprecation-webhook --version v0.1.0`, apply
  `examples/demo-deprecated/scaledobject.yaml` — must be rejected by the
  admission webhook.
- Apply a known-good ScaledObject — must be admitted.

### keda-labs after the cleanup PR

- `make up` from a clean cluster succeeds end-to-end.
- `kubectl get pod -n keda-system -l app.kubernetes.io/name=keda-deprecation-webhook`
  shows running pods.
- `kubectl get validatingwebhookconfiguration keda-deprecation-webhook` exists
  and has CA bundle injected by cert-manager.
- Grafana shows "KEDA Deprecations" dashboard with no broken panels.
- `make kdw-demo` results in the deprecated ScaledObject being rejected.

## Risks & rollback

| Risk | Mitigation |
|---|---|
| Module path rewrite leaves stragglers | Gate Step 2 on `go build ./...` and `go vet ./...` before pushing. |
| Chart defaults drift from current manifests behavior (replicas, failurePolicy, cert duration, CA injection annotations) | Step 2.7 includes a `helm template` vs `kdw/manifests/deploy/*.yaml` diff, attached to the new repo's initial PR description. |
| Dashboard raw-GitHub fetch fails in offline environments | Chart's `dashboard.enabled` CM is the fallback. `install-grafana.sh` can fall back to `kubectl -n keda-system get cm kdw-dashboard -o jsonpath` after `helm install` if `curl` fails. Document this in `install-grafana.sh` but don't auto-fallback on day one. |
| Release workflow misconfigured (wrong permissions, missing GHCR token, chart-releaser GH Pages branch absent) | Step 3.1 dry-runs with `v0.0.0-rc1` before the real `v0.1.0`. |
| keda-labs's lab breaks after cleanup PR | Two-commit structure: revert commit 2 (or commit 1 too) brings back the vendored `kdw/` immediately. |

## Open items (re-evaluate post-extraction)

- Whether to add e2e CI in the new repo (suggest revisiting after first
  external user files an issue or the chart gains its first non-trivial
  value).
- Whether to migrate keda-labs's Grafana to a sidecar-based dashboard
  provisioner so the chart's `dashboard.enabled=true` is the canonical
  install path. Today's raw-fetch approach is fine for a single-consumer
  lab.
- Whether to also publish the chart to GHCR as an OCI artifact (modern
  alternative to chart-releaser + GH Pages). Defer.
