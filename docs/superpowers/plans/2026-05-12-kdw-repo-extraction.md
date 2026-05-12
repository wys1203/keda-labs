# kdw → standalone repo extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `kdw/` from `keda-labs` into the standalone OSS repo
`github.com/wys1203/keda-deprecation-webhook`, publish `v0.1.0` (image to
GHCR, chart to GH Pages), and switch `keda-labs` to consume it as a thin
helm-install client.

**Architecture:** Phase A builds the new-repo content in a throwaway working
tree under `/tmp/kdw-extract` (history preserved via `git filter-repo`),
adds a Helm chart and CI/release workflows, and verifies locally on a kind
cluster. Phase B pushes to GitHub and cuts `v0.1.0` (after a rc dry-run).
Phase C lands a two-commit PR in `keda-labs` that swaps scripts/Makefile to
helm-install and then deletes `kdw/`.

**Tech Stack:** Go 1.25, Helm v3 (chart-releaser-action), GitHub Actions,
ghcr.io for images, GitHub Pages for the helm repo, cert-manager (already
required by lab), kind for smoke tests.

**Spec:** `docs/superpowers/specs/2026-05-12-kdw-repo-extraction-design.md`
(approved 2026-05-12).

**Working assumptions an executor needs:**
- This plan runs from a checkout of `keda-labs` (this repo). The `keda-labs`
  remote is `origin` at `github.com/wys1203/keda-labs`.
- The user `wys1203` is the GitHub owner of both repos; they will perform
  the one `gh repo create` step in Task B1 (or grant me permission to via
  their `gh` auth).
- Tools available locally: `git`, `git-filter-repo`, `go` 1.25+, `helm` v3,
  `kubectl`, `kind`, `docker`, `gh`, `yq`. Plan verifies these in Task A0.
- All Phase A work happens in `/tmp/kdw-extract` (the future new repo
  content), **not** inside `keda-labs`. Phase C runs back inside `keda-labs`
  on a feature branch.

---

## Phase A — Build the new repo content locally

### Task A0: Prereq check

**Files:** none (read-only verification).

- [ ] **Step 1: Verify required tools**

```bash
for cmd in git git-filter-repo go helm kubectl kind docker gh yq; do
  command -v "$cmd" >/dev/null || { echo "MISSING: $cmd"; exit 1; }
done
helm version --short
go version
kind version
```

Expected: all commands resolve, helm reports `v3.x`, go reports `go1.25.x`.
If `git-filter-repo` is missing: `brew install git-filter-repo` (macOS) or
`pip install git-filter-repo`.

- [ ] **Step 2: Verify `keda-labs` is clean**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-labs
git status --porcelain
git rev-parse --abbrev-ref HEAD
```

Expected: empty output (clean tree). Branch can be anything; we won't
modify it during Phase A.

---

### Task A1: Extract `kdw/` history with `git filter-repo`

**Files:**
- Create (new working tree): `/tmp/kdw-extract/` (entire directory).

- [ ] **Step 1: Clone keda-labs into a throwaway path**

```bash
rm -rf /tmp/kdw-extract
git clone /Users/wys1203/go/src/github.com/wys1203/keda-labs /tmp/kdw-extract
cd /tmp/kdw-extract
```

Expected: clone succeeds, `cd` puts us in the throwaway tree.

- [ ] **Step 2: Filter to `kdw/` subdirectory**

```bash
git filter-repo --subdirectory-filter kdw
```

Expected: filter-repo prints `Parsed N commits` then `New history written`.
After this, `kdw/`'s contents are at repo root.

- [ ] **Step 3: Sanity-check the filtered tree**

```bash
ls
git log --oneline | head -20
git log --oneline | wc -l
```

Expected: `cmd/`, `internal/`, `manifests/`, `scripts/`, `demo/`,
`Dockerfile`, `go.mod`, `dashboard.json`, `test/` are at top level. Commit
count should be > 1 (whatever touched `kdw/` historically; today this is
mostly commit 47e1b72 and a few predecessors).

- [ ] **Step 4: Remove the now-meaningless origin remote**

```bash
git remote remove origin
git remote -v
```

Expected: no remotes listed. (We'll add the new remote in Phase B.)

- [ ] **Step 5: Commit checkpoint (no actual commit — history is the commit)**

No commit needed. The filter rewrote history. Confirm state:

```bash
git status
```

Expected: clean tree.

---

### Task A2: Rename Go module and rewrite import paths

**Files:**
- Modify: `/tmp/kdw-extract/go.mod`
- Modify: any `.go` file containing `github.com/wys1203/keda-labs/kdw`

- [ ] **Step 1: Find every reference to the old module path**

```bash
cd /tmp/kdw-extract
grep -rln 'github.com/wys1203/keda-labs/kdw' .
```

Expected: at least `go.mod`, several files under `cmd/` and `internal/`.

- [ ] **Step 2: Rewrite the module path**

```bash
grep -rl 'github.com/wys1203/keda-labs/kdw' . \
  | xargs sed -i '' 's|github.com/wys1203/keda-labs/kdw|github.com/wys1203/keda-deprecation-webhook|g'
```

Note: `sed -i ''` is the macOS form. On Linux: `sed -i 's|...|...|g'`.

- [ ] **Step 3: Verify no leftovers**

```bash
grep -rln 'github.com/wys1203/keda-labs/kdw' . || echo OK
```

Expected: `OK` (no matches).

- [ ] **Step 4: Verify Go build + vet + tests still pass**

```bash
go mod tidy
go build ./...
go vet ./...
go test ./...
```

Expected: all green. If `go mod tidy` makes changes to go.mod/go.sum,
that's fine — those are the rename-driven updates.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename module to github.com/wys1203/keda-deprecation-webhook"
```

---

### Task A3: Restructure tree for standalone repo layout

**Files:**
- Rename: `/tmp/kdw-extract/demo/` → `/tmp/kdw-extract/examples/`
- Delete: `/tmp/kdw-extract/scripts/install-webhook.sh` (replaced by chart)
- Delete: `/tmp/kdw-extract/scripts/verify-webhook.sh` (lab-specific, stays in keda-labs)
- Delete: `/tmp/kdw-extract/manifests/` (replaced by `charts/` in Task A5)
- Modify: `/tmp/kdw-extract/.gitignore` (add `dist/`, `bin/`, `*.tgz`)

- [ ] **Step 1: Rename `demo/` to `examples/`**

```bash
git mv demo examples
ls examples/
```

Expected: `examples/demo-deprecated/` contains the original deprecated SO
manifests.

- [ ] **Step 2: Remove lab-specific scripts**

```bash
git rm scripts/install-webhook.sh scripts/verify-webhook.sh
rmdir scripts 2>/dev/null || true   # remove if now empty
ls scripts 2>/dev/null && echo "(scripts dir still has content)" || echo "(scripts dir removed)"
```

Expected: scripts dir is gone, or contains only items we keep. (If keep,
list them in the commit message.)

- [ ] **Step 3: Keep `manifests/` for now**

We don't delete `manifests/` yet — Task A6 uses it as the source of truth
for the `helm template` diff. We'll delete it after the chart is verified.

- [ ] **Step 4: Update `.gitignore`**

Open `/tmp/kdw-extract/.gitignore` (create if missing) and ensure it
contains:

```gitignore
# Build outputs
/dist/
/bin/
keda-deprecation-webhook

# Helm packaging
*.tgz

# Editor / OS
.DS_Store
.idea/
.vscode/
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename demo to examples, drop lab-only scripts, gitignore build outputs"
```

---

### Task A4: Helm chart skeleton — Chart.yaml + values.yaml

**Files:**
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/Chart.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/values.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/.helmignore`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/_helpers.tpl`

- [ ] **Step 1: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: keda-deprecation-webhook
description: A validating admission webhook that flags deprecated KEDA ScaledObject and ScaledJob fields.
type: application
version: 0.1.0
appVersion: "0.1.0"
kubeVersion: ">=1.27.0-0"
home: https://github.com/wys1203/keda-deprecation-webhook
sources:
  - https://github.com/wys1203/keda-deprecation-webhook
keywords:
  - keda
  - autoscaling
  - admission-webhook
  - deprecation
maintainers:
  - name: wys1203
    url: https://github.com/wys1203
annotations:
  artifacthub.io/category: monitoring-logging
```

- [ ] **Step 2: Write `values.yaml`**

```yaml
# Default values for keda-deprecation-webhook.
# Mirrors current kdw/manifests/deploy/* defaults so an out-of-the-box
# install behaves like the previous lab vendoring.

image:
  repository: ghcr.io/wys1203/keda-deprecation-webhook
  tag: ""              # defaults to .Chart.AppVersion
  pullPolicy: IfNotPresent
  pullSecrets: []

replicaCount: 2

namespace:
  create: false        # set true to have the chart create the install namespace

serviceAccount:
  create: true
  name: ""             # defaults to fullname

rbac:
  create: true

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi

webhook:
  failurePolicy: Ignore   # matches current VWC
  timeoutSeconds: 5
  port: 9443
  metricsPort: 8080
  probesPort: 8081

service:
  prometheus:
    scrape: true        # adds prometheus.io/scrape annotations

pdb:
  enabled: true
  maxUnavailable: 1

certificate:
  duration: 8760h
  renewBefore: 720h
  # If using your own issuer instead of the self-signed one bundled here,
  # set issuer.name + issuer.kind and the chart will skip its Issuer.
  issuer:
    name: ""
    kind: ""

# Deprecation rules consumed by the webhook config-map. Mirrors the
# default-error / no-overrides shape; lab users add namespaceOverrides.
rules:
  - id: KEDA001
    defaultSeverity: error
    namespaceOverrides: []

dashboard:
  enabled: false       # set true to install the Grafana dashboard CM
                       # (labeled grafana_dashboard=1 for sidecar pickup)

nodeSelector: {}
tolerations: []
affinity: {}
```

- [ ] **Step 3: Write `.helmignore`**

```gitignore
.DS_Store
.git/
.gitignore
.idea/
.vscode/
*.tgz
README.md.gotmpl
```

- [ ] **Step 4: Write `templates/_helpers.tpl`**

```yaml
{{/* Standard Helm chart name + fullname helpers */}}
{{- define "keda-deprecation-webhook.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keda-deprecation-webhook.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "keda-deprecation-webhook.labels" -}}
app.kubernetes.io/name: {{ include "keda-deprecation-webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "keda-deprecation-webhook.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keda-deprecation-webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "keda-deprecation-webhook.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "keda-deprecation-webhook.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 5: Sanity check**

```bash
cd /tmp/kdw-extract
helm lint charts/keda-deprecation-webhook
```

Expected: `1 chart(s) linted, 0 chart(s) failed`. (Warnings about icon/etc.
are fine.)

- [ ] **Step 6: Commit**

```bash
git add charts/
git commit -m "feat(chart): scaffold Chart.yaml, values.yaml, helpers"
```

---

### Task A5: Templatize the eight manifests

**Files:**
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/namespace.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/serviceaccount.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/rbac.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/configmap-rules.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/service.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/deployment.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/pdb.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/certificate.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/validatingwebhookconfiguration.yaml`
- Create: `/tmp/kdw-extract/charts/keda-deprecation-webhook/templates/configmap-dashboard.yaml`

For each template below, use literal file content (no placeholders).

- [ ] **Step 1: `namespace.yaml`**

```yaml
{{- if .Values.namespace.create -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
{{- end -}}
```

- [ ] **Step 2: `serviceaccount.yaml`**

```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "keda-deprecation-webhook.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
{{- end -}}
```

- [ ] **Step 3: `rbac.yaml`** (Role + RoleBinding + ClusterRole + ClusterRoleBinding)

```yaml
{{- if .Values.rbac.create -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "keda-deprecation-webhook.fullname" . }}
subjects:
  - kind: ServiceAccount
    name: {{ include "keda-deprecation-webhook.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["keda.sh"]
    resources: ["scaledobjects", "scaledjobs"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "keda-deprecation-webhook.fullname" . }}
subjects:
  - kind: ServiceAccount
    name: {{ include "keda-deprecation-webhook.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
{{- end -}}
```

- [ ] **Step 4: `configmap-rules.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}-config
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
data:
  config.yaml: |
{{ toYaml (dict "rules" .Values.rules) | indent 4 }}
```

- [ ] **Step 5: `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
  {{- if .Values.service.prometheus.scrape }}
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "{{ .Values.webhook.metricsPort }}"
    prometheus.io/path: /metrics
  {{- end }}
spec:
  selector:
    {{- include "keda-deprecation-webhook.selectorLabels" . | nindent 4 }}
  ports:
    - name: webhook
      port: 443
      targetPort: {{ .Values.webhook.port }}
      protocol: TCP
    - name: metrics
      port: {{ .Values.webhook.metricsPort }}
      targetPort: {{ .Values.webhook.metricsPort }}
      protocol: TCP
```

- [ ] **Step 6: `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "keda-deprecation-webhook.selectorLabels" . | nindent 6 }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        {{- include "keda-deprecation-webhook.selectorLabels" . | nindent 8 }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap-rules.yaml") . | sha256sum }}
    spec:
      serviceAccountName: {{ include "keda-deprecation-webhook.serviceAccountName" . }}
      {{- with .Values.image.pullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: webhook
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args:
            - --metrics-bind-address=:{{ .Values.webhook.metricsPort }}
            - --health-probe-bind-address=:{{ .Values.webhook.probesPort }}
            - --webhook-port={{ .Values.webhook.port }}
            - --cert-dir=/etc/webhook/certs
            - --config-map-name={{ include "keda-deprecation-webhook.fullname" . }}-config
          env:
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: REJECT_MESSAGE_URL
              value: ""
          ports:
            - name: webhook
              containerPort: {{ .Values.webhook.port }}
            - name: metrics
              containerPort: {{ .Values.webhook.metricsPort }}
            - name: probes
              containerPort: {{ .Values.webhook.probesPort }}
          livenessProbe:
            httpGet: { path: /healthz, port: probes }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: probes }
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: certs
              mountPath: /etc/webhook/certs
              readOnly: true
      volumes:
        - name: certs
          secret:
            secretName: {{ include "keda-deprecation-webhook.fullname" . }}-tls
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

- [ ] **Step 7: `pdb.yaml`**

```yaml
{{- if .Values.pdb.enabled -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
spec:
  maxUnavailable: {{ .Values.pdb.maxUnavailable }}
  selector:
    matchLabels:
      {{- include "keda-deprecation-webhook.selectorLabels" . | nindent 6 }}
{{- end -}}
```

- [ ] **Step 8: `certificate.yaml`**

```yaml
{{- $fullName := include "keda-deprecation-webhook.fullname" . -}}
{{- if and (empty .Values.certificate.issuer.name) (empty .Values.certificate.issuer.kind) }}
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: {{ $fullName }}-selfsigned
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
spec:
  selfSigned: {}
---
{{- end }}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ $fullName }}-serving-cert
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
spec:
  secretName: {{ $fullName }}-tls
  duration: {{ .Values.certificate.duration }}
  renewBefore: {{ .Values.certificate.renewBefore }}
  dnsNames:
    - {{ $fullName }}.{{ .Release.Namespace }}.svc
    - {{ $fullName }}.{{ .Release.Namespace }}.svc.cluster.local
  issuerRef:
    name: {{ default (printf "%s-selfsigned" $fullName) .Values.certificate.issuer.name }}
    kind: {{ default "Issuer" .Values.certificate.issuer.kind }}
```

- [ ] **Step 9: `validatingwebhookconfiguration.yaml`**

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
  annotations:
    cert-manager.io/inject-ca-from: {{ .Release.Namespace }}/{{ include "keda-deprecation-webhook.fullname" . }}-serving-cert
webhooks:
  - name: vkdw.keda.sh
    failurePolicy: {{ .Values.webhook.failurePolicy }}
    sideEffects: None
    admissionReviewVersions: ["v1"]
    timeoutSeconds: {{ .Values.webhook.timeoutSeconds }}
    matchPolicy: Equivalent
    rules:
      - apiGroups: ["keda.sh"]
        apiVersions: ["v1alpha1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["scaledobjects", "scaledjobs"]
    clientConfig:
      service:
        namespace: {{ .Release.Namespace }}
        name: {{ include "keda-deprecation-webhook.fullname" . }}
        path: /validate-keda-sh-v1alpha1
        port: 443
```

- [ ] **Step 10: `configmap-dashboard.yaml`**

```yaml
{{- if .Values.dashboard.enabled -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "keda-deprecation-webhook.fullname" . }}-dashboard
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "keda-deprecation-webhook.labels" . | nindent 4 }}
    grafana_dashboard: "1"
data:
  keda-deprecations.json: |-
{{ .Files.Get "dashboard.json" | indent 4 }}
{{- end -}}
```

Note: `.Files.Get "dashboard.json"` reads `dashboard.json` from the chart
root. Helm 3 supports this when `dashboard.json` sits beside `Chart.yaml`,
but our `dashboard.json` is at the repo root. So either symlink or copy:

```bash
cp /tmp/kdw-extract/dashboard.json /tmp/kdw-extract/charts/keda-deprecation-webhook/dashboard.json
```

Add a CI check in Task A8 that the two files match (or have the chart copy
be authoritative — but the spec keeps dashboard.json at repo root for
keda-labs to raw-fetch, so we copy and add a CI diff check).

- [ ] **Step 11: Verify the chart renders**

```bash
cd /tmp/kdw-extract
helm lint charts/keda-deprecation-webhook
helm template kdw charts/keda-deprecation-webhook \
  --namespace keda-system \
  --set namespace.create=true \
  --set dashboard.enabled=true \
  > /tmp/kdw-rendered.yaml
echo "rendered $(wc -l < /tmp/kdw-rendered.yaml) lines"
```

Expected: lint passes; template renders without errors; the rendered file
contains a Namespace, ServiceAccount, Role, RoleBinding, ClusterRole,
ClusterRoleBinding, ConfigMap (rules), Service, Deployment, PDB, Issuer,
Certificate, ValidatingWebhookConfiguration, ConfigMap (dashboard).

- [ ] **Step 12: Commit**

```bash
git add charts/ dashboard.json
git commit -m "feat(chart): templatize all manifests"
```

---

### Task A6: Verify chart matches existing manifests (diff gate)

**Files:**
- Create: `/tmp/kdw-extract/hack/chart-vs-manifests-diff.sh`

This script renders the chart with lab-equivalent values and diffs against
the original `manifests/` (still present from filter-repo). Once the diff
is acceptable, we delete `manifests/`.

- [ ] **Step 1: Write the diff script**

`/tmp/kdw-extract/hack/chart-vs-manifests-diff.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Render the chart with lab-equivalent values, normalize, and diff against
# the original kdw/manifests/deploy/ output. Surfaces drift before we
# delete the source-of-truth manifests.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

old_dir="$(mktemp -d)"
new_dir="$(mktemp -d)"
trap 'rm -rf "$old_dir" "$new_dir"' EXIT

# Original manifests, normalized via `kubectl apply --dry-run=client -o yaml`
# so server-side defaults are added equivalently to the rendered chart.
cat "${ROOT_DIR}/manifests/deploy/"*.yaml > "${old_dir}/combined.yaml"

helm template kdw "${ROOT_DIR}/charts/keda-deprecation-webhook" \
  --namespace keda-system \
  --set image.tag=dev \
  --set image.repository=keda-deprecation-webhook \
  --set namespace.create=true \
  --set rules[0].id=KEDA001 \
  --set rules[0].defaultSeverity=error \
  --set 'rules[0].namespaceOverrides[0].names[0]=legacy-cpu' \
  --set 'rules[0].namespaceOverrides[0].severity=warn' \
  > "${new_dir}/combined.yaml"

# yq-normalize both: sort keys, strip helm.sh/chart label, strip release
# annotations / managed-by labels that are pure helm metadata, and rename
# release-prefixed names back to their bare form for comparison.
normalize() {
  yq eval-all '
    sort_keys(..) |
    del(.metadata.labels."helm.sh/chart") |
    del(.metadata.labels."app.kubernetes.io/instance") |
    del(.metadata.labels."app.kubernetes.io/managed-by") |
    del(.spec.template.metadata.labels."app.kubernetes.io/instance") |
    del(.spec.selector.matchLabels."app.kubernetes.io/instance") |
    del(.spec.template.metadata.annotations."checksum/config")
  ' "$1"
}

diff <(normalize "${old_dir}/combined.yaml") <(normalize "${new_dir}/combined.yaml") \
  | tee /tmp/kdw-chart-diff.txt

echo
echo "Diff written to /tmp/kdw-chart-diff.txt"
```

Make executable:

```bash
chmod +x /tmp/kdw-extract/hack/chart-vs-manifests-diff.sh
```

- [ ] **Step 2: Run the diff**

```bash
cd /tmp/kdw-extract
./hack/chart-vs-manifests-diff.sh
```

Expected differences (acceptable — these are chart-management noise that
the normalize step doesn't strip 100%):
- Resource names with `kdw-` prefix vs no prefix (release name normalization).
- `kdw-tls` secret name → `kdw-keda-deprecation-webhook-tls` (chart fullname).
- `kdw-selfsigned` Issuer → `kdw-keda-deprecation-webhook-selfsigned`.
- Selector/label expansions for the standard helm label set.

**Unacceptable differences** that block the gate:
- Different `failurePolicy`, `replicas`, container args, resource limits,
  cert duration, RBAC rules, webhook rules, probe paths/ports.

If unacceptable diff found: fix the template and re-run until only naming
noise remains.

- [ ] **Step 3: Document accepted differences in `hack/CHART-DIFF.md`**

Create `/tmp/kdw-extract/hack/CHART-DIFF.md` capturing the acceptable
diff categories so future maintainers know what the diff script will show:

```markdown
# Accepted chart-vs-manifests diffs

Run `./hack/chart-vs-manifests-diff.sh` to compare the rendered chart
against the original `manifests/deploy/`. The following differences are
acceptable and considered chart-management noise:

- **Resource names** carry the helm release name prefix
  (e.g. `keda-deprecation-webhook` → `kdw-keda-deprecation-webhook` when
  installed as `helm install kdw ...`).
- **Secret name** for the serving cert is now release-scoped
  (`<release>-keda-deprecation-webhook-tls`); ValidatingWebhookConfiguration
  and Deployment volume references update in lock-step.
- **Self-signed Issuer name** is release-scoped.
- **Labels:** chart adds `app.kubernetes.io/instance`,
  `app.kubernetes.io/managed-by`, `helm.sh/chart`.
- **Deployment annotations:** `checksum/config` is added to roll pods on
  rules CM change.

Anything outside this list is a real drift and must be reconciled before
release.
```

- [ ] **Step 4: Delete the now-redundant `manifests/` and `Makefile` (if any)**

```bash
cd /tmp/kdw-extract
git rm -r manifests/
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(chart): diff gate vs manifests/, remove manifests/"
```

---

### Task A7: OSS housekeeping (LICENSE, README, CONTRIBUTING, SECURITY)

**Files:**
- Create: `/tmp/kdw-extract/LICENSE`
- Create: `/tmp/kdw-extract/README.md`
- Create: `/tmp/kdw-extract/CONTRIBUTING.md`
- Create: `/tmp/kdw-extract/SECURITY.md`

- [ ] **Step 1: `LICENSE` — Apache 2.0**

Copy verbatim from <https://www.apache.org/licenses/LICENSE-2.0.txt>. The
plain text version. Set the copyright line at the bottom (if applicable)
to "Copyright 2026 wys1203".

- [ ] **Step 2: `README.md`**

```markdown
# keda-deprecation-webhook

A Kubernetes validating admission webhook that flags deprecated fields in
KEDA `ScaledObject` and `ScaledJob` resources. Configurable per-rule
severity (error / warn / off) with namespace-level overrides.

Originally extracted from
[wys1203/keda-labs](https://github.com/wys1203/keda-labs), which remains
the reference deployment lab.

## Install

Requires Kubernetes ≥ 1.27 and cert-manager.

```bash
helm repo add kdw https://wys1203.github.io/keda-deprecation-webhook
helm repo update
helm install kdw kdw/keda-deprecation-webhook \
  --namespace keda-system --create-namespace
```

By default `KEDA001` (CPU/memory ScaleTarget) is rejected with severity
`error`. Override per namespace:

```bash
helm upgrade kdw kdw/keda-deprecation-webhook -n keda-system \
  --reuse-values \
  --set 'rules[0].namespaceOverrides[0].names[0]=legacy-cpu' \
  --set 'rules[0].namespaceOverrides[0].severity=warn'
```

## Verify

```bash
kubectl apply -f https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/v0.1.0/examples/demo-deprecated/
# Expected: scaledobject.yaml is rejected with KEDA001 in the message.
```

## Configuration

See [`charts/keda-deprecation-webhook/values.yaml`](charts/keda-deprecation-webhook/values.yaml).

## Development

```bash
go test ./...
helm lint charts/keda-deprecation-webhook
./hack/chart-vs-manifests-diff.sh   # against the old manifests/, kept for parity
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
```

- [ ] **Step 3: `CONTRIBUTING.md`**

```markdown
# Contributing

## Local development

- Go 1.25+
- `helm` v3
- `kind` (for end-to-end testing)

### Building

```bash
go build ./...
go test ./...
```

### Chart changes

Run `helm lint charts/keda-deprecation-webhook` before committing.

### Filing issues

When reporting a bug, please include:
- Kubernetes version (`kubectl version`)
- KEDA version
- Chart version (`helm list -A | grep keda-deprecation-webhook`)
- The exact `ScaledObject` / `ScaledJob` manifest that triggered the issue

### Pull requests

- One topic per PR.
- Include tests where applicable.
- Run `go vet ./...` and `helm lint` locally before pushing.

## Project status

This is an extraction from a personal lab project. Issue triage and
review may be infrequent.
```

- [ ] **Step 4: `SECURITY.md`**

```markdown
# Security Policy

## Reporting a vulnerability

Please do **not** open a public issue for security-sensitive findings.
Instead, email <wys1203@gmail.com> with:

- A description of the vulnerability
- Steps to reproduce
- Affected versions

You should receive an acknowledgement within 7 days. I will investigate
and prepare a fix; coordinated disclosure window is up to 90 days
depending on severity.

## Supported versions

Only the latest minor release is supported with security fixes during
this project's pre-1.0 phase.
```

- [ ] **Step 5: Commit**

```bash
git add LICENSE README.md CONTRIBUTING.md SECURITY.md
git commit -m "docs: add LICENSE, README, CONTRIBUTING, SECURITY"
```

---

### Task A8: GitHub Actions — `ci.yaml`

**Files:**
- Create: `/tmp/kdw-extract/.github/workflows/ci.yaml`
- Create: `/tmp/kdw-extract/.golangci.yml`

- [ ] **Step 1: `.golangci.yml`** (golangci-lint v2 schema — required by `golangci-lint-action@v7`)

```yaml
version: "2"

run:
  timeout: 5m

linters:
  default: none
  enable:
    - errcheck
    - govet
    - ineffassign
    - staticcheck
    - misspell

formatters:
  enable:
    - gofmt
    - goimports
  settings:
    goimports:
      local-prefixes:
        - github.com/wys1203/keda-deprecation-webhook
```

> Note: golangci-lint v2 reorganized the config schema — `disable-all` is replaced by `default: none`, and `gofmt`/`goimports` are now **formatters** (top-level `formatters:` block), not linters. Use `golangci-lint-action@v7` (v6 only supports v1 config).

- [ ] **Step 2: `.github/workflows/ci.yaml`**

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  go:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          cache: true
      - run: go vet ./...
      - run: go test -race -coverprofile=coverage.out ./...
      - name: golangci-lint
        uses: golangci/golangci-lint-action@v7
        with:
          version: v2.12.2
      - uses: actions/upload-artifact@v4
        with:
          name: coverage
          path: coverage.out

  chart:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@v4
        with:
          version: v3.16.0
      - run: helm lint charts/keda-deprecation-webhook
      - run: |
          helm template kdw charts/keda-deprecation-webhook \
            --namespace keda-system --set namespace.create=true \
            --set dashboard.enabled=true \
            > /tmp/rendered.yaml
          test -s /tmp/rendered.yaml
      - name: Verify chart dashboard matches repo-root dashboard
        run: diff dashboard.json charts/keda-deprecation-webhook/dashboard.json

  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: false
          tags: keda-deprecation-webhook:ci
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yaml .golangci.yml
git commit -m "ci: add Go + chart + image build workflow"
```

---

### Task A9: GitHub Actions — `release.yaml` + chart-releaser

**Files:**
- Create: `/tmp/kdw-extract/.github/workflows/release.yaml`
- Create: `/tmp/kdw-extract/.github/cr.yaml`

- [ ] **Step 1: `.github/cr.yaml`** (chart-releaser config)

```yaml
owner: wys1203
git-repo: keda-deprecation-webhook
package-path: .cr-release-packages
index-path: index.yaml
charts-repo: https://wys1203.github.io/keda-deprecation-webhook
release-name-template: "chart-{{ .Version }}"
```

- [ ] **Step 2: `.github/workflows/release.yaml`**

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: write   # for chart-releaser to push to gh-pages
  packages: write   # for GHCR push

jobs:
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Compute image tag
        id: tag
        run: echo "value=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          platforms: linux/amd64,linux/arm64
          tags: |
            ghcr.io/wys1203/keda-deprecation-webhook:${{ steps.tag.outputs.value }}
            ghcr.io/wys1203/keda-deprecation-webhook:latest

  chart:
    runs-on: ubuntu-latest
    needs: image
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Configure Git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
      - uses: azure/setup-helm@v4
        with:
          version: v3.16.0
      - name: chart-releaser
        uses: helm/chart-releaser-action@v1.6.0
        with:
          charts_dir: charts
          config: .github/cr.yaml
          skip_existing: true
        env:
          CR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 3: Sanity-check workflow YAML syntax**

```bash
cd /tmp/kdw-extract
yq eval '.' .github/workflows/release.yaml > /dev/null && echo OK
yq eval '.' .github/workflows/ci.yaml > /dev/null && echo OK
```

Expected: two `OK`s.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yaml .github/cr.yaml
git commit -m "ci: add release workflow (image to GHCR, chart via chart-releaser)"
```

---

### Task A10: Local kind smoke test

**Files:** none (in-cluster verification).

This is the final pre-push gate: install the chart on a fresh kind cluster
and confirm both the positive and negative admission paths work.

- [ ] **Step 1: Spin up a throwaway kind cluster**

```bash
kind create cluster --name kdw-smoke
kubectl cluster-info --context kind-kdw-smoke
```

Expected: cluster reports Ready.

- [ ] **Step 2: Install prerequisites (cert-manager and KEDA)**

```bash
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version v1.16.2 \
  --set crds.enabled=true --wait
helm install keda kedacore/keda \
  --namespace keda --create-namespace --wait
```

Expected: both helm releases report `STATUS: deployed`.

- [ ] **Step 3: Build local image and load into kind**

```bash
cd /tmp/kdw-extract
docker build -t keda-deprecation-webhook:smoke .
kind load docker-image keda-deprecation-webhook:smoke --name kdw-smoke
```

Expected: image built and loaded.

- [ ] **Step 4: Install the chart**

```bash
helm install kdw ./charts/keda-deprecation-webhook \
  --namespace keda-system --create-namespace \
  --set image.repository=keda-deprecation-webhook \
  --set image.tag=smoke \
  --set image.pullPolicy=IfNotPresent \
  --wait --timeout 2m
kubectl -n keda-system get pods,svc,vwc,certificate
```

Expected: Deployment Ready, Service exists, ValidatingWebhookConfiguration
exists, Certificate `Ready=True`.

- [ ] **Step 5: Negative case — deprecated SO must be rejected**

```bash
kubectl apply -f examples/demo-deprecated/namespace.yaml
kubectl apply -f examples/demo-deprecated/deployment.yaml
kubectl apply -f examples/demo-deprecated/scaledobject.yaml
```

Expected: the `scaledobject.yaml` apply fails with an error message
containing `KEDA001`.

- [ ] **Step 6: Positive case — a valid SO must be admitted**

Use a minimal Kafka SO (any non-CPU/memory trigger works):

```bash
kubectl -n demo-deprecated apply -f - <<'EOF'
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ok-so
spec:
  scaleTargetRef:
    name: nginx
  triggers:
    - type: kubernetes-workload
      metadata:
        podSelector: "app=nginx"
        value: "1"
EOF
```

Expected: `scaledobject.keda.sh/ok-so created`.

- [ ] **Step 7: Tear down**

```bash
kind delete cluster --name kdw-smoke
```

- [ ] **Step 8: No commit needed (smoke test is verification only)**

If everything passed: proceed to Phase B. If anything failed: fix the
template, run the diff script again, re-smoke before continuing.

---

## Phase B — Push and release

### Task B1: Create GitHub repo and push

**Files:** none (remote operations).

- [ ] **Step 1: Create the empty GitHub repo**

```bash
gh repo create wys1203/keda-deprecation-webhook \
  --public \
  --description "Validating admission webhook flagging deprecated KEDA ScaledObject/ScaledJob fields." \
  --homepage "https://wys1203.github.io/keda-deprecation-webhook"
```

Expected: `✓ Created repository wys1203/keda-deprecation-webhook on GitHub`.

- [ ] **Step 2: Add remote and push**

```bash
cd /tmp/kdw-extract
git remote add origin https://github.com/wys1203/keda-deprecation-webhook.git
git branch -M main
git push -u origin main
```

Expected: push succeeds; default branch on GitHub is `main`.

- [ ] **Step 3: Verify CI ran**

Open <https://github.com/wys1203/keda-deprecation-webhook/actions> and
confirm the CI workflow ran against the initial push. All three jobs
(`go`, `chart`, `image`) should be green.

If a job is red: fix locally, push, repeat until green.

---

### Task B2: Configure GH Pages branch for chart-releaser

**Files:** none (remote configuration).

- [ ] **Step 1: Create an empty `gh-pages` branch on the remote**

```bash
cd /tmp/kdw-extract
git checkout --orphan gh-pages
git rm -rf .
echo "# chart-releaser will populate this branch" > README.md
git add README.md
git commit -m "init: gh-pages for chart-releaser"
git push -u origin gh-pages
git checkout main
```

Expected: `gh-pages` exists on origin with one commit.

- [ ] **Step 2: Enable GitHub Pages for the branch**

```bash
gh api -X POST repos/wys1203/keda-deprecation-webhook/pages \
  -f source.branch=gh-pages -f source.path=/
gh api repos/wys1203/keda-deprecation-webhook/pages \
  --jq '.html_url'
```

Expected: `https://wys1203.github.io/keda-deprecation-webhook/`. Pages may
take 1–2 minutes to come up; refresh until reachable.

---

### Task B3: Dry-run release with `v0.0.0-rc1`

**Files:** none (tag operation).

- [ ] **Step 1: Tag the rc**

```bash
cd /tmp/kdw-extract
git tag v0.0.0-rc1
git push origin v0.0.0-rc1
```

Expected: Release workflow at
<https://github.com/wys1203/keda-deprecation-webhook/actions> kicks off.

- [ ] **Step 2: Wait for workflow completion and verify artifacts**

```bash
gh run watch --repo wys1203/keda-deprecation-webhook
```

Expected: both `image` and `chart` jobs green.

- [ ] **Step 3: Verify image is on GHCR**

```bash
docker pull ghcr.io/wys1203/keda-deprecation-webhook:0.0.0-rc1
```

Expected: pull succeeds. (Image visibility may need to be set to Public via
<https://github.com/users/wys1203/packages/container/keda-deprecation-webhook/settings>;
do that on first push.)

- [ ] **Step 4: Verify chart is in the helm repo**

```bash
helm repo add kdw https://wys1203.github.io/keda-deprecation-webhook
helm repo update
helm search repo kdw
```

Expected: `kdw/keda-deprecation-webhook` row showing version `0.0.0-rc1`.

- [ ] **Step 5: Delete the rc tag (optional cleanup, fine to leave)**

```bash
git push origin :refs/tags/v0.0.0-rc1
git tag -d v0.0.0-rc1
gh release delete v0.0.0-rc1 --repo wys1203/keda-deprecation-webhook --yes 2>/dev/null || true
```

- [ ] **Step 6: If anything failed: fix in main, re-push, re-tag a new rc.**

---

### Task B4: Cut `v0.1.0`

**Files:** none (tag operation).

- [ ] **Step 1: Tag**

```bash
cd /tmp/kdw-extract
git tag v0.1.0
git push origin v0.1.0
```

- [ ] **Step 2: Wait for release workflow**

```bash
gh run watch --repo wys1203/keda-deprecation-webhook
```

Expected: both jobs green.

- [ ] **Step 3: Verify**

```bash
docker pull ghcr.io/wys1203/keda-deprecation-webhook:0.1.0
helm repo update
helm search repo kdw --versions | head -5
```

Expected: image pullable; `kdw/keda-deprecation-webhook 0.1.0` listed.

- [ ] **Step 4: Edit the GitHub release notes**

```bash
gh release edit v0.1.0 --repo wys1203/keda-deprecation-webhook \
  --notes "Initial release. Extracted from github.com/wys1203/keda-labs. See README for install instructions."
```

---

## Phase C — Switch `keda-labs` to consume the chart

All Phase C work happens **inside `/Users/wys1203/go/src/github.com/wys1203/keda-labs`**, not the extraction working tree. Each task lists exact paths in `keda-labs`.

### Task C0: Stay on the spec/plan branch

The current branch `kdw-extraction-spec` already carries the spec and plan
docs that Phase C's tombstone (C2) cross-references. Phase C's commits 1
and 2 land on top of those doc commits so the whole extraction ships as
one PR.

**Files:** none.

- [ ] **Step 1: Verify branch state**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-labs
git rev-parse --abbrev-ref HEAD
git status --porcelain
git log --oneline -5
```

Expected: branch is `kdw-extraction-spec`; working tree clean; recent
commits include `docs(spec): correct kdw extraction values ...` and
`docs(plan): kdw repo extraction implementation plan`.

---

### Task C1: Commit 1 — switch lab to consume the chart (keep `kdw/` in place)

**Files:**
- Modify: `scripts/lib.sh`
- Modify: `Makefile`
- Modify: `scripts/up.sh`
- Modify: `lab/scripts/install-grafana.sh`
- Create: `lab/charts/values-kdw-lab.yaml`
- Create: `lab/scripts/install-webhook.sh` (replaces `kdw/scripts/install-webhook.sh`)
- Create: `lab/scripts/verify-webhook.sh` (replaces `kdw/scripts/verify-webhook.sh`)
- Create: `lab/scripts/demo-deprecated.sh` (replaces the embedded recipe in Makefile)

- [ ] **Step 1: Update `scripts/lib.sh`**

Replace `KDW_DIR="${ROOT_DIR}/kdw"` (line 6) with:

```bash
KDW_VERSION="${KDW_VERSION:-v0.1.0}"
KDW_NAMESPACE="${KDW_NAMESPACE:-keda-system}"
KDW_HELM_REPO_URL="${KDW_HELM_REPO_URL:-https://wys1203.github.io/keda-deprecation-webhook}"
KDW_HELM_RELEASE="${KDW_HELM_RELEASE:-kdw}"
```

Remove the `KDW_DIR` line entirely.

- [ ] **Step 2: Create `lab/charts/values-kdw-lab.yaml`**

```yaml
# Lab-specific overrides for keda-deprecation-webhook.
# Mirrors the previous kdw/manifests/deploy/configmap.yaml so the lab's
# legacy-cpu demo demonstrates warn-mode without being permanently
# rejected.

rules:
  - id: KEDA001
    defaultSeverity: error
    namespaceOverrides:
      - names: ["legacy-cpu"]
        severity: warn
```

- [ ] **Step 3: Create `lab/scripts/install-webhook.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd helm

log "adding kdw helm repo"
helm repo add kdw "${KDW_HELM_REPO_URL}" >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing keda-deprecation-webhook ${KDW_VERSION} from helm repo"
helm upgrade --install "${KDW_HELM_RELEASE}" kdw/keda-deprecation-webhook \
  --version "${KDW_VERSION#v}" \
  --namespace "${KDW_NAMESPACE}" --create-namespace \
  --values "${ROOT_DIR}/lab/charts/values-kdw-lab.yaml" \
  --wait --timeout 2m

# Lab-specific: the chart's namespace template does not carry the
# prodsuite label that lab monitoring uses to group workloads.
# Apply it after helm install.
kubectl label namespace "${KDW_NAMESPACE}" prodsuite=Platform --overwrite

log "keda-deprecation-webhook ${KDW_VERSION} ready"
```

Make executable:

```bash
chmod +x lab/scripts/install-webhook.sh
```

- [ ] **Step 4: Create `lab/scripts/verify-webhook.sh`**

This is the existing `kdw/scripts/verify-webhook.sh`, adapted to:
- Reference `${KDW_NAMESPACE}` (already defined in lib.sh).
- Apply demo manifests by URL from the pinned `${KDW_VERSION}`.
- Restore the CM via `helm upgrade --reuse-values` rather than re-applying
  a static `configmap.yaml`.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd kubectl
require_cmd helm

DEMO_NS="demo-deprecated"
KDW_BASE_URL="https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}"

kdw_curl() {
  local url="$1"
  kubectl -n "${KDW_NAMESPACE}" run "kdw-curl-$$-${RANDOM}" \
    --attach --rm --restart=Never -i --quiet \
    --image=curlimages/curl:8.10.1 \
    --command -- curl -fsS "${url}"
}

# 1. Pod healthy
log "checking pod health"
kubectl -n "${KDW_NAMESPACE}" rollout status deployment/${KDW_HELM_RELEASE}-keda-deprecation-webhook --timeout=60s

# 2. /metrics
log "checking /metrics"
metrics="$(kdw_curl "http://${KDW_HELM_RELEASE}-keda-deprecation-webhook.${KDW_NAMESPACE}.svc:8080/metrics")"
echo "${metrics}" | grep -q '^keda_deprecation_config_generation' \
  || fail "config_generation metric missing"
log "metrics OK"

# 3. Negative: deprecated SO must be rejected
log "applying demo-deprecated SO (expect rejection)"
kubectl apply -f "${KDW_BASE_URL}/examples/demo-deprecated/namespace.yaml"
kubectl apply -f "${KDW_BASE_URL}/examples/demo-deprecated/deployment.yaml"
set +e
APPLY_OUT="$(kubectl apply -f "${KDW_BASE_URL}/examples/demo-deprecated/scaledobject.yaml" 2>&1)"
APPLY_RC=$?
set -e
echo "${APPLY_OUT}"
[[ ${APPLY_RC} -ne 0 ]] || fail "expected webhook rejection, but apply succeeded"
echo "${APPLY_OUT}" | grep -q "KEDA001" \
  || fail "expected KEDA001 in rejection message, got: ${APPLY_OUT}"
log "rejection OK"

# 4. legacy-cpu warn-mode gauge
log "checking warn-mode gauge for legacy-cpu"
metrics="$(kdw_curl "http://${KDW_HELM_RELEASE}-keda-deprecation-webhook.${KDW_NAMESPACE}.svc:8080/metrics")"
echo "${metrics}" \
  | grep 'keda_deprecation_violations{' \
  | grep 'namespace="legacy-cpu"' \
  | grep 'severity="warn"' \
  || fail "expected violations{namespace=legacy-cpu, severity=warn} not found"
log "warn-mode gauge OK"

# 5. Hot-reload: flip legacy-cpu to off, expect series to update.
log "hot-reloading rules to severity=off for legacy-cpu via helm upgrade"
helm upgrade "${KDW_HELM_RELEASE}" kdw/keda-deprecation-webhook \
  --version "${KDW_VERSION#v}" \
  --namespace "${KDW_NAMESPACE}" \
  --reuse-values \
  --set 'rules[0].namespaceOverrides[0].names[0]=legacy-cpu' \
  --set 'rules[0].namespaceOverrides[0].severity=off' \
  --wait --timeout 1m

log "waiting up to 60s for severity flip to propagate"
seen_off=0
for _ in {1..30}; do
  metrics="$(kdw_curl "http://${KDW_HELM_RELEASE}-keda-deprecation-webhook.${KDW_NAMESPACE}.svc:8080/metrics" || true)"
  if echo "${metrics}" | grep 'keda_deprecation_violations{' \
      | grep 'namespace="legacy-cpu"' | grep -q 'severity="off"'; then
    seen_off=1; break
  fi
  sleep 2
done
[[ ${seen_off} -eq 1 ]] || fail "expected severity=off series after upgrade, not seen"

# 6. Restore lab values
log "restoring lab values"
helm upgrade "${KDW_HELM_RELEASE}" kdw/keda-deprecation-webhook \
  --version "${KDW_VERSION#v}" \
  --namespace "${KDW_NAMESPACE}" \
  --values "${ROOT_DIR}/lab/charts/values-kdw-lab.yaml" \
  --wait --timeout 1m

log "verify-webhook: all checks passed"
```

```bash
chmod +x lab/scripts/verify-webhook.sh
```

- [ ] **Step 5: Update `scripts/up.sh`**

Change line 13 from:

```bash
"${ROOT_DIR}/kdw/scripts/install-webhook.sh"
```

to:

```bash
"${ROOT_DIR}/lab/scripts/install-webhook.sh"
```

- [ ] **Step 6: Update `lab/scripts/install-grafana.sh`**

Replace the `--from-file=keda-deprecations.json="${KDW_DIR}/dashboard.json"`
in the `grafana-dashboards` CM creation with a raw GitHub fetch at the
pinned version. Insert before the existing `kubectl create configmap
grafana-dashboards ...` block:

```bash
# Fetch the kdw dashboard at the pinned KDW_VERSION (defined in scripts/lib.sh)
KDW_DASHBOARD_TMP="$(mktemp -t kdw-dashboard.XXXXXX.json)"
trap 'rm -f "${KDW_DASHBOARD_TMP}"' EXIT
log "fetching kdw dashboard ${KDW_VERSION}"
curl -fsSL "https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}/dashboard.json" \
  -o "${KDW_DASHBOARD_TMP}"
```

Then change the `--from-file=keda-deprecations.json=...` line to:

```bash
  --from-file=keda-deprecations.json="${KDW_DASHBOARD_TMP}" \
```

- [ ] **Step 7: Create `lab/scripts/demo-deprecated.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

BASE="https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}/examples/demo-deprecated"

kubectl apply -f "${BASE}/namespace.yaml"
kubectl apply -f "${BASE}/deployment.yaml"
# scaledobject is expected to be rejected by the webhook (KEDA001).
kubectl apply -f "${BASE}/scaledobject.yaml" || true
```

```bash
chmod +x lab/scripts/demo-deprecated.sh
```

- [ ] **Step 8: Update `Makefile`**

Replace the `# --- KDW (kdw/scripts/) ---` section (lines 111-125) with:

```makefile
# --- KDW (consumed from github.com/wys1203/keda-deprecation-webhook) ---
install-webhook:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./lab/scripts/install-webhook.sh

verify-webhook:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./lab/scripts/verify-webhook.sh

demo-deprecated:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./lab/scripts/demo-deprecated.sh
```

Also remove the `build-webhook` target (image now comes from GHCR) and
remove `build-webhook` from the `.PHONY` list (lines 17-20). The help
block (around line 30) has no `make build-webhook` entry — leave the help
block alone.

- [ ] **Step 9: Verify shellcheck on the changed scripts**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-labs
shellcheck lab/scripts/install-webhook.sh lab/scripts/verify-webhook.sh lab/scripts/demo-deprecated.sh lab/scripts/install-grafana.sh scripts/up.sh scripts/lib.sh 2>/dev/null \
  || echo "(shellcheck not installed; skip)"
```

Expected: no errors. If shellcheck isn't installed, this skip is fine.

- [ ] **Step 10: Commit**

```bash
git add scripts/lib.sh scripts/up.sh Makefile \
  lab/scripts/install-grafana.sh lab/scripts/install-webhook.sh \
  lab/scripts/verify-webhook.sh lab/scripts/demo-deprecated.sh \
  lab/charts/values-kdw-lab.yaml
git commit -m "feat(lab): consume keda-deprecation-webhook chart v0.1.0 from helm repo"
```

---

### Task C2: Update documentation references

**Files:**
- Modify: `README.md`
- Modify: `docs/keda-deprecation-webhook-zh-TW.md`
- Modify: `docs/lab-overview.md`
- Modify: `docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md`
- Modify: `docs/superpowers/plans/2026-05-09-keda-deprecation-webhook.md`

- [ ] **Step 1: Update `README.md`**

Find every mention of `kdw/manifests/`, `kdw/dashboard.json`,
`kdw/Dockerfile`, `make build-webhook`, and `kdw/` as a directory pointer,
and update to:
- Webhook lives at <https://github.com/wys1203/keda-deprecation-webhook>.
- Install via `make install-webhook` which uses the chart at the pinned
  `KDW_VERSION`.
- Dashboard ships in the new repo; the lab fetches it at install time.

Add a "Component" subsection near the existing kdw section:

```markdown
### keda-deprecation-webhook

The webhook lives in its own repo at
[wys1203/keda-deprecation-webhook](https://github.com/wys1203/keda-deprecation-webhook).
The lab pins it via `KDW_VERSION` in `scripts/lib.sh` and installs it via
`helm` (`make install-webhook`). Lab-specific rule overrides live in
`lab/charts/values-kdw-lab.yaml`.
```

- [ ] **Step 2: Update `docs/keda-deprecation-webhook-zh-TW.md`**

This is the Chinese-language deep-dive. Replace any source-code references
(`kdw/internal/...`) with GitHub-pinned URLs at the same paths
(`github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/internal/...`).
The conceptual content (rule schema, severity model, namespace overrides)
does not need to change.

- [ ] **Step 3: Update `docs/lab-overview.md`**

Replace mentions of `kdw/scripts/install-webhook.sh` with
`lab/scripts/install-webhook.sh`. Add a sentence noting the webhook is now
external.

- [ ] **Step 4: Update prior spec / plan with a tombstone note**

Prepend to `docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md`:

```markdown
> **2026-05-12 update:** the webhook described here was extracted into a
> standalone repo. See
> [`2026-05-12-kdw-repo-extraction-design.md`](./2026-05-12-kdw-repo-extraction-design.md)
> for the extraction design. This document remains as historical record
> of the original in-monorepo design.
```

Same tombstone, adjusted wording, for
`docs/superpowers/plans/2026-05-09-keda-deprecation-webhook.md`.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/
git commit -m "docs: point kdw references at the standalone repo, tombstone old design"
```

---

### Task C3: Lab end-to-end verification

**Files:** none (cluster verification).

- [ ] **Step 1: Recreate the lab cluster from scratch**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-labs
make down 2>/dev/null || true
make up
```

Expected: all `lab/scripts/*.sh` succeed, and the new
`lab/scripts/install-webhook.sh` is the one that runs (not `kdw/scripts/`).

- [ ] **Step 2: Verify webhook pods are up**

```bash
kubectl -n keda-system get pod -l app.kubernetes.io/name=keda-deprecation-webhook
kubectl get validatingwebhookconfiguration kdw-keda-deprecation-webhook
```

Expected: 2 pods Running. The VWC name is now release-prefixed.

- [ ] **Step 3: Run the new verify script**

```bash
make verify-webhook
```

Expected: all six checks pass (pod, metrics, rejection, warn gauge,
hot-reload off, restore).

- [ ] **Step 4: Confirm Grafana dashboard renders**

```bash
make grafana &
sleep 5
curl -sf http://localhost:3000/api/dashboards/uid/keda-deprecations | head -5
```

Expected: dashboard JSON returned (not 404). Press Ctrl-C to stop the
port-forward.

- [ ] **Step 5: Stop here if anything failed; debug and amend Commit 1.**

If everything passes, proceed to Task C4.

---

### Task C4: Commit 2 — delete `kdw/` from the lab

**Files:**
- Delete: `kdw/` (entire directory)
- Delete: `keda-deprecation-webhook` (root build artifact, ~2.5 MB binary)

- [ ] **Step 1: Confirm the binary at root is the build artifact, not a typo**

```bash
file /Users/wys1203/go/src/github.com/wys1203/keda-labs/keda-deprecation-webhook
```

Expected: `Mach-O 64-bit executable` (or similar). This is a stale local
build; it should be deleted.

- [ ] **Step 2: Delete `kdw/` and the binary**

```bash
git rm -r kdw/
git rm keda-deprecation-webhook
```

- [ ] **Step 3: Sanity check — no other paths reference `kdw/`**

```bash
grep -rln 'kdw/' --include='*.sh' --include='*.yaml' --include='*.yml' \
  --include='Makefile' --include='*.md' . 2>/dev/null \
  | grep -v '^./.git/' \
  | grep -v 'docs/superpowers/specs/2026-05-05' \
  | grep -v 'docs/superpowers/plans/2026-05-09' \
  || echo OK
```

Expected: `OK` or only matches in the tombstoned old spec/plan (which we
explicitly chose to leave as historical record).

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(lab): remove vendored kdw/ now that the chart ships v0.1.0"
```

---

### Task C5: Push and open PR

**Files:** none.

- [ ] **Step 1: Push branch**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-labs
git push -u origin kdw-extraction-spec
```

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "feat(kdw): extract to github.com/wys1203/keda-deprecation-webhook, consume v0.1.0" \
  --body "$(cat <<'EOF'
## Summary

- Extracts `kdw/` into a standalone OSS repo: <https://github.com/wys1203/keda-deprecation-webhook>.
- Lab now installs the webhook via `helm` from <https://wys1203.github.io/keda-deprecation-webhook>, pinned to `v0.1.0`.
- Lab-specific rules (legacy-cpu → warn) live in `lab/charts/values-kdw-lab.yaml`.
- Dashboard is fetched from raw GitHub at the pinned version inside `install-grafana.sh`.

## Commits

1. **feat(lab): consume keda-deprecation-webhook chart v0.1.0 from helm repo** — adds the new lab scripts, values, Makefile targets; keeps `kdw/` in tree so this commit is independently runnable.
2. **feat(lab): remove vendored kdw/** — removes `kdw/` and the root binary artifact.

Split this way to keep rollback cheap: revert commit 2 brings `kdw/` back; revert both restores the old install path.

## Test plan

- [ ] `make down && make up` from a clean state succeeds end-to-end.
- [ ] `make verify-webhook` passes (all six checks).
- [ ] Grafana shows the "KEDA Deprecations" dashboard with live panels.
- [ ] `make demo-deprecated` results in the ScaledObject being rejected.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Confirm PR opened, capture URL**

The previous command prints the PR URL. Save it for the user; the
extraction work is complete when this PR is reviewed and merged.

---

## Done — exit criteria

- New repo `wys1203/keda-deprecation-webhook` exists, public, with `v0.1.0`
  tag and GH Actions all green.
- `ghcr.io/wys1203/keda-deprecation-webhook:0.1.0` is publicly pullable.
- `helm repo add kdw https://wys1203.github.io/keda-deprecation-webhook`
  works and `helm search repo kdw` shows `0.1.0`.
- PR `feat(kdw): extract ...` is open against `keda-labs:main` and its test
  plan passes.

After merge:
- The keda-labs `MEMORY.md` entry "Grafana dashboards are ConfigMap-baked"
  remains accurate (we still rebuild the CM); update it if the future
  Grafana-sidecar migration in the spec's "Open items" gets picked up.

---

## Post-execution notes (added 2026-05-13 after PR #8)

Issues surfaced during the actual run; the plan body above has been
patched where it would have misled a copy-paste reader. Other observations
captured here as context for future similar extractions:

- **B3 rc dry-run does not validate the chart job.** `chart-releaser-action`
  uses the `version:` field in `Chart.yaml`, **not** the git tag. So tagging
  `v0.0.0-rc1` against a chart that says `version: 0.1.0` publishes `chart-0.1.0`
  immediately. Treat B3 as image-only validation; the chart side is
  effectively validated by B4.
- **B4 `v0.1.0` chart job fails the second time** when `chart-0.1.0`
  release already exists. The plan now has `skip_existing: true` for
  this reason. The first real release with this option enabled is
  idempotent.
- **No `v<tag>` GitHub release** is created by `chart-releaser-action`.
  It only creates `chart-<chart-version>` releases. If a `v<tag>` release
  with curated notes is desired, run `gh release create v<tag> ...`
  manually after the workflow completes. (Done for `v0.1.0`.)
- **Lab kind cluster must be k8s ≥ 1.27** to install the chart
  (`kubeVersion: ">=1.27.0-0"`). `lab/kind/cluster.yaml` was on
  `kindest/node:v1.24.17`; bumped to `v1.29.4` as part of `C3`'s fix
  commit (`1e0856c`).
- **`helm --set` on a list element is a full-element replacement.**
  C1's `verify-webhook.sh` hot-reload step used
  `--reuse-values --set rules[0].namespaceOverrides[0].severity=off`,
  which replaced the entire `rules[0]` and dropped its `id` and
  `defaultSeverity` fields. The webhook then rejected the config and
  the readiness probe flipped to 500. Specify the full `rules[0]` shape
  in the `--set` chain (or stage values into a tmp YAML file and
  `helm upgrade -f`).
