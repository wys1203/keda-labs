# keda-deprecation-webhook 操作手冊(繁體中文)

> 適用版本:本 lab 的 `kdw` branch / PR #7。
> 對應的英文設計規格:[`docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md`](superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md)
> 對應的英文實作計畫:[`docs/superpowers/plans/2026-05-09-keda-deprecation-webhook.md`](superpowers/plans/2026-05-09-keda-deprecation-webhook.md)
>
> 本文件以實際操作為主,假設讀者是負責 KEDA 升級的 platform/SRE。

---

## 1. 為什麼需要這個 Webhook

### 背景

KEDA `2.18` 對 `ScaledObject` / `ScaledJob` 的 CPU/Memory trigger 引入了 **不可回退的 breaking change**:

> CPU/Memory trigger 不再允許使用 `triggers[].metadata.type`,改為強制使用 `triggers[].metricType`。

也就是這種**會壞掉**的舊寫法:

```yaml
triggers:
  - type: cpu
    metadata:
      type: Utilization        # ← 2.18 開始 unmarshal 失敗
      value: "50"
```

必須改成:

```yaml
triggers:
  - type: cpu
    metricType: Utilization    # ← 正確寫法
    metadata:
      value: "50"
```

升級 KEDA `2.16 → 2.18` 之前,如果不掃出並修掉這些舊規格,被影響的 ScaledObject 會在新版本上**直接停止運作**(HPA 不再 scale)。

### 解決方案

`keda-deprecation-webhook`(以下簡稱 **KDW**)是一支 Go 寫的 Kubernetes operator,提供兩條路徑:

1. **Admission 攔截** —— 阻擋會引入新 deprecation 的 `kubectl apply`。
2. **Inventory 觀測** —— 用 Prometheus gauge 把整個叢集現存的 deprecation 全部列出來,讓 platform 跟各 team owner 都看得到「還有哪些要修」。

KDW 目前內建一條規則 `KEDA001`(CPU/Memory `metadata.type`),框架可擴充。

---

## 2. 架構一覽

```
                   ┌─────────────────────────────────────────┐
                   │   keda-deprecation-webhook (KDW)        │
                   │   namespace: keda-system                │
                   │   2 replicas + PDB                      │
                   │                                         │
   apiserver ────► │ :9443  ValidatingWebhookConfiguration   │ ─── 所有 replica
   (HTTPS)         │       /validate-keda-sh-v1alpha1        │      都跑
                   │                                         │
                   │ :8080  /metrics  (Prometheus)           │ ─── 所有 replica
                   │ :8081  /healthz, /readyz                │      都跑
                   │                                         │
                   │ ConfigMap watcher (hot reload)          │ ─── 所有 replica
                   │ Namespace watcher (label cache)         │      都跑
                   │                                         │
                   │ ScaledObject / ScaledJob 控制器         │ ─── 只在 leader
                   │   (gauge metric emission)               │      replica 跑
                   └─────────────────────────────────────────┘
                              ▲
                              │  (cert-manager 簽發 TLS,
                              │   cainjector 注入 CA bundle)
                              │
                          kdw-tls Secret
```

### 關鍵設計決策

| 決策 | 選擇 | 理由 |
|---|---|---|
| `failurePolicy` | `Ignore` | Lint 類 webhook 應該 fail open。Pod 掛掉時 admission 不卡,Controller 端最終會把漏網的 deprecation 透過 metric 暴露出來 |
| Webhook 範圍 | `ScaledObject` + `ScaledJob` | 兩者 `Spec.Triggers[]` shape 相同,規則一次套用 |
| UPDATE 模式 | **加性執行(additive-only)** | UPDATE 只 reject 那些「**新增**」的 error 違規;原本就有 deprecation 但這次沒讓它變糟的 UPDATE 直接放行(只發 warning)。讓 owner 可以邊修 maxReplicaCount 邊不被擋 |
| CREATE 模式 | 嚴格 | 任何新建立的 SO/SJ 帶 error 違規一律 reject |
| Diff key | `(RuleID, TriggerType, Field)` | **不含** `TriggerIndex` —— 純粹調換 `triggers[]` 順序不會被誤判為新增違規 |
| Severity 來源 | **熱重載 ConfigMap** | 100+ 叢集要做 per-namespace 微調時,不需要 rebuild image |
| TLS | cert-manager `selfSigned` Issuer | 自動續期,跟 lab 的 KEDA TLS 同一條路徑 |
| Mutating Webhook | **不採用** | 自動修會把債藏起來,本工具的目標就是「讓 owner 看到」 |

### 副本責任分工

| 元件 | 範圍 | 為什麼 |
|---|---|---|
| Admission webhook 伺服器 | 每個 replica | apiserver 走 Service,任何 replica 都要能正確判決 admission |
| ConfigMap watcher | 每個 replica | 每顆 pod 自己讀 CM,確保 admission 判決時用的是最新 config |
| Namespace label watcher | 每個 replica | 同上,resolveing severity 時要查 namespace label |
| `ScaledObject` / `ScaledJob` 控制器(寫 gauge) | 只在 leader | 寫 gauge 是 single-writer 工作,雙寫會 race + double-count |
| Counter metrics(rejects/warnings) | 每個 replica 各自 emit | Prometheus 的 `sum(rate(...))` 標準 pattern,無 double-count 風險 |

### 啟動就緒順序

KDW pod 的 `readinessProbe` 會在 ConfigMap watcher 完成第一次 reconcile **之前**回傳 500。這是刻意的:在 store 裡還是空 config 的時候,Service 不會把這顆 pod 加進 endpoints,apiserver 也就不會把 admission 流量送過來。**這是讓「config 還沒讀到」不會導致誤判 reject 的關鍵保險**。

---

## 3. 部署到 Lab

> 全部已經接進 `make up`,如果你跑 `make recreate` 就什麼都會自己起來。下面是逐項說明。

### 3.1 自動部署(推薦)

```bash
make up           # 從 0 起整個 lab(含 KDW)
# 或
make recreate     # 砍掉再重建
```

`scripts/up.sh` 的執行順序(KDW 介於 KEDA 跟 demo 之間):

```
prereq-check → create-cluster → label-zones → prepull-images
  → install-monitoring (含 prometheus + grafana)
  → install-keda      (含 cert-manager,KEDA 自己依賴)
  → install-webhook   ← KDW 在這一步建起來
  → deploy-demo       (含 demo-cpu, demo-prom, legacy-cpu)
  → verify
```

`legacy-cpu` 在 lab 預設 CM 裡被設成 `severity: warn`,所以 deploy-demo 階段 apply 它的時候會看到一行 `Warning: [KEDA001] ...` 但**會成功**。

### 3.2 手動部署 / Rebuild

```bash
make build-webhook       # docker build + kind load + apply manifests
make install-webhook     # 同上(若 image 沒變只 apply manifests)
make verify-webhook      # 跑 6 步 E2E 驗證
make demo-deprecated     # 故意 apply 一個違規 SO,預期被 reject
```

### 3.3 Manifest 結構

Helm chart 的 templates 目錄(位於 [wys1203/keda-deprecation-webhook](https://github.com/wys1203/keda-deprecation-webhook)):

| 檔案 | 用途 |
|---|---|
| `namespace.yaml` | `keda-system` namespace,標 `prodsuite=Platform` |
| `rbac.yaml` | SA + Role(同 ns 的 CM/Events/Leases)+ ClusterRole(讀 Namespaces / SO / SJ) |
| `certificate.yaml` | cert-manager `Issuer` (selfSigned) + `Certificate`(1 年期、30 天前 renew) |
| `configmap.yaml` | KDW 自己的 config —— **大部分操作只會動這個檔案** |
| `service.yaml` | `443→9443` (webhook) + `8080→8080` (metrics),帶 Prometheus scrape annotation |
| `deployment.yaml` | 2 replicas、probes、resource limits |
| `pdb.yaml` | `maxUnavailable: 1` |
| `validatingwebhookconfiguration.yaml` | VWC,`failurePolicy: Ignore`,帶 `cert-manager.io/inject-ca-from` |

---

## 4. ConfigMap 設定

> **這是日常操作 90% 會碰到的東西**,務必看懂。

### 4.1 Lab 預設 CM

`lab/charts/values-kdw-lab.yaml`(透過 Helm values 傳入):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: keda-deprecation-webhook-config
  namespace: keda-system
data:
  config.yaml: |
    rules:
      - id: KEDA001
        defaultSeverity: error      # 預設:CREATE 帶 deprecation 一律 reject
        namespaceOverrides:
          - names: ["legacy-cpu"]
            severity: warn          # 例外:legacy-cpu ns 只發 warning
```

意義:**新建立的 SO/SJ 一律不准帶 deprecation,但 `legacy-cpu` 這個 namespace 既有的 deprecation 我們暫時放它一馬**。

### 4.2 Schema 完整定義

```yaml
rules:
  - id: <string>                      # e.g. "KEDA001"。必填
    defaultSeverity: error|warn|off   # 必填
    namespaceOverrides:               # 選填
      - names: ["a", "b-*", "c?"]     # shell-glob:`*` 萬用、`?` 單字元
        severity: warn
      # 或
      - labelSelector:                # 標準 metav1.LabelSelector
          matchLabels:
            tier: legacy
          matchExpressions:
            - { key: env, operator: In, values: ["dev","sandbox"] }
        severity: "off"
      # 注意:每一條 entry 必須是 **names 或 labelSelector 二擇一**,不能同時設,也不能都不設
```

`severity` 的可用值:

```
"error"   "warn"   "off"
```

### 4.3 Severity 行為對照表

| 設定 | CREATE 帶違規 | UPDATE 引入新違規 | UPDATE 維持原狀 | Admission Warning | Gauge metric |
|---|---|---|---|---|---|
| `error` | **reject** | **reject** | 放行(發 warning) | ✅ | ✅ `severity="error"` |
| `warn` | 放行 | 放行 | 放行 | ✅ | ✅ `severity="warn"` |
| `off` | 放行 | 放行 | 放行 | ❌ | ✅ `severity="off"` |

`off` 仍會 emit gauge —— 即使 namespace 被豁免,**整個 fleet 的 dashboard 還是看得到這個債**,不會被默默藏起來。

### 4.4 First-match-wins

`namespaceOverrides[]` 是**由上而下、第一個 match 的 entry 拿到 severity**。所以最具體的 entry 要寫在最前面:

```yaml
namespaceOverrides:
  - names: ["payments-prod"]      # 最具體
    severity: error
  - labelSelector:                # 比較廣的條件墊後
      matchLabels: { tier: legacy }
    severity: warn
```

如果一個 namespace 同時 match 兩條,會拿到第一條的 `error`。

### 4.5 ⚠️ YAML 1.1 的 `off` 陷阱

`sigs.k8s.io/yaml` 底層走 yaml.v2(YAML 1.1),**未加引號的 `off` 會被當成布林 `false`**,然後嚴格反序列化到 `Severity`(string)時會 reject。

**這樣寫會壞:**
```yaml
severity: off    # ❌ YAML 1.1 解析成 false,parse 失敗
```

**這樣寫才對:**
```yaml
severity: "off"  # ✅ 字串
```

`error` 跟 `warn` 沒這個問題。

### 4.6 熱重載

CM 改完 `kubectl apply` 之後,**所有 replica** 的 watcher 會在幾秒內偵測到並重新 parse:

- 成功 → store 替換新 config、`keda_deprecation_config_generation` +1、所有 SO/SJ 重新 lint(gauge 的 `severity` label 立刻翻新,舊系列被刪除避免鬼魂)。
- 失敗(YAML 壞、severity 不合法等)→ **保留上一份好 config**、emit `keda_deprecation_config_reloads_total{result="error"}` 計數、在該 CM 上產生一個 `Warning: InvalidConfig` Event。

### 4.7 常見編輯場景

```bash
# 看現在用的 CM
kubectl -n keda-system get cm keda-deprecation-webhook-config -o yaml

# 改成「整個 fleet 都先用 warn-mode」(rollout 第一階段)
kubectl -n keda-system edit cm keda-deprecation-webhook-config
# (把 defaultSeverity 從 error 改成 warn)

# 看是否成功 reload
kubectl -n keda-system logs -l app.kubernetes.io/name=keda-deprecation-webhook --tail=5 | grep "config reloaded"

# 看 generation 計數有沒有跳
kubectl -n keda-system port-forward svc/keda-deprecation-webhook 8080:8080 &
curl -s http://localhost:8080/metrics | grep keda_deprecation_config_generation
```

---

## 5. 觀測性

### 5.1 Metrics

`/metrics` endpoint 暴露在 `keda-deprecation-webhook.keda-system.svc:8080`,被既有的 `kubernetes-service-endpoints` Prometheus job 自動抓取。

#### Gauge —— 現存違規(每筆違規一條 series)

```
keda_deprecation_violations{
  namespace,            # SO/SJ 所在 ns
  kind,                 # ScaledObject | ScaledJob
  name,                 # SO/SJ 名稱
  trigger_index,        # "0", "1", ...(物件層級違規時為 "-1")
  trigger_type,         # "cpu", "memory", ""
  rule_id,              # "KEDA001"
  severity,             # 套用 CM 後的有效 severity
} = 1
```

> **重要不變式**:這個 gauge 永遠是「現在的真相」。SO 被刪、違規被修、severity 被翻成新的值,對應的舊 series 都會在下一個 reconcile cycle 被 `DeleteLabelValues` 清掉。**不會留鬼魂系列**。

#### Counters —— 事件累積

```
keda_deprecation_admission_rejects_total{namespace, kind, rule_id, operation}    # operation = CREATE | UPDATE
keda_deprecation_admission_warnings_total{namespace, kind, rule_id}
keda_deprecation_config_reloads_total{result}                                    # result = success | error
```

#### 健康指標

```
keda_deprecation_config_generation    # 單調遞增,每次成功 reload +1
```

### 5.2 Alert 規則(Prometheus)

加在 `lab/prometheus/values.yaml` 的 `keda-deprecations` group(共 3 條):

| Alert | 觸發條件 | Severity | Tier | 意義 |
|---|---|---|---|---|
| `KedaDeprecationWebhookDown` | `up{...} == 0` 持續 5 分鐘 | critical | 2 | webhook 失聯;`failurePolicy: Ignore` 期間可能漏網,Controller 端會在恢復後重新補 metric |
| `KedaDeprecationConfigReloadFailing` | `increase(...{result="error"}[10m]) > 0` 持續 **5 分鐘** | warning | 2 | CM 無法 parse,正在用上一份好 config。`for: 0m → 5m`,單次 parse 失敗不再響(由 2026-05-12 alert-tier audit 調整) |
| `KedaDeprecationErrorViolationsPresent` | `sum(violations{severity="error"}) > 0` 持續 1 小時 | **info** | 3 | 還有 fleet 範圍內的 error 級違規,2.18 升級前必須清掉。**Tier 3 info,不進 pager**(由 2026-05-12 alert-tier audit 從 warning 降到 info) |

> 補充:本 webhook 的 alert 依新的三層分類:`KedaDeprecationWebhookDown` 與 `KedaDeprecationConfigReloadFailing` 是 Tier 2(platform pager),`KedaDeprecationErrorViolationsPresent` 是 Tier 3(`severity: info`,只給 dashboard 看,不進 pager)。完整 audit 設計見 `docs/superpowers/specs/2026-05-12-keda-platform-alerts-design.md`。

### 5.3 Grafana Dashboard

UID: `keda-deprecations`,標題 **KEDA Deprecations**。9 個面板:

| # | 類型 | 內容 |
|---|---|---|
| 1 | Stat | error 違規總數(紅燈) |
| 2 | Stat | warn 違規總數(黃燈) |
| 3 | Stat | off 違規總數(豁免但仍是技術債) |
| 4 | Stat | `config_generation`(目前的 config 版次) |
| 5 | Time series | 各 severity 違規數量隨時間變化(觀察 migration 進度) |
| 6 | Table | 每筆違規的 namespace / kind / name / trigger_index / trigger_type / rule_id / severity |
| 7 | Time series | 7 天內各 namespace × rule_id 的 admission reject 速率 |
| 8 | Time series | 7 天內各 namespace × rule_id 的 admission warning 速率 |
| 9 | Stat | 7 天內 config reload 失敗次數(>0 紅燈) |

模板變數:`Datasource`、`Prodsuite`、`Namespace` —— 跟其他 KEDA dashboard 一致,跨 dashboard 切換不會丟篩選條件。

---

## 6. 操作手冊

### 6.1 看現在 fleet 有哪些 deprecation

```bash
make grafana                  # port-forward Grafana 到 localhost:3000
# 開瀏覽器找「KEDA Deprecations」dashboard,看 panel #6 的 table
```

或用 PromQL 直查:

```promql
keda_deprecation_violations{severity!="off"}
```

### 6.2 給某個 namespace 開臨時豁免(warn-mode)

```bash
kubectl -n keda-system edit cm keda-deprecation-webhook-config
```

加一條 override:

```yaml
namespaceOverrides:
  - names: ["team-x-prod"]
    severity: warn
```

存檔。**不需要重啟 pod**,幾秒內就會生效。看 log 確認:

```bash
kubectl -n keda-system logs -l app.kubernetes.io/name=keda-deprecation-webhook --tail=3 | grep "config reloaded"
```

### 6.3 暫時把整個 fleet 切回 warn-mode(rollout 第一階段)

```yaml
data:
  config.yaml: |
    rules:
      - id: KEDA001
        defaultSeverity: warn      # 全 fleet 都改成 warn,不再 reject
```

幾秒內生效。整個 fleet 的 admission 開始放行 deprecation(只發 warning),Grafana 上 violations 會從 `severity="error"` 翻到 `severity="warn"`,舊的 error 系列自動消失。

### 6.4 演練:確認 reject 路徑

```bash
make demo-deprecated
```

預期看到:

```
Error from server (Forbidden): admission webhook "vkdw.keda.sh" denied the request:
rejected by keda-deprecation-webhook:
  - [KEDA001] trigger[0] (type=cpu): metadata.type is deprecated since KEDA 2.10 and removed in 2.18
    — Use triggers[0].metricType: Utilization instead.
```

對應的 metric counter `keda_deprecation_admission_rejects_total{namespace="demo-deprecated", rule_id="KEDA001", operation="CREATE"}` 也會 +1。

### 6.5 完整 lab E2E

```bash
make verify-webhook
```

涵蓋 6 個檢查:pod ready → /metrics 可達 → demo-deprecated 被 reject → legacy-cpu 的 warn-mode gauge 存在 → CM 熱重載 severity 翻轉(`warn → off`)後 ghost series 消失 → CM 還原。預期全綠。

---

## 7. 故障排除

### 7.1 我 apply 一個 SO 結果被擋,但這個 namespace 我以為設了 warn

**檢查清單:**

1. **CM 是不是真的在 keda-system?**
   ```bash
   kubectl -n keda-system get cm keda-deprecation-webhook-config
   ```

2. **CM 內容對不對?**
   ```bash
   kubectl -n keda-system get cm keda-deprecation-webhook-config -o yaml
   ```
   特別注意 `severity: off` 是不是有加引號(YAML 1.1 陷阱,見 4.5)。

3. **CM 是不是 reload 失敗,還在用上一份?**
   ```bash
   kubectl -n keda-system get events --field-selector involvedObject.name=keda-deprecation-webhook-config
   kubectl -n keda-system port-forward svc/keda-deprecation-webhook 8080:8080 &
   curl -s http://localhost:8080/metrics | grep keda_deprecation_config_reloads_total
   ```
   如果 `result="error"` 計數 > 0,parse 出問題,看 events 上的訊息。

4. **Namespace match 對不對?**
   - 用 `names:` 的話,**glob 是 shell-glob 不是 regex**(`*`、`?` 而已,沒有 `[a-z]` 字元類)。
   - 用 `labelSelector` 的話,確認 namespace 真的有那個 label。
   ```bash
   kubectl get ns <YOUR_NS> --show-labels
   ```

5. **是不是 first-match-wins 命中前一條?**
   重看你的 `namespaceOverrides[]` 順序,**第一個 match 的就停**。

### 7.2 Pod 一直不 Ready

**症狀:**
```
0/1 Running, READY=False
Readiness probe failed: HTTP probe failed with statuscode: 500
```

**根因順序:**

1. **CM watcher 沒 reconcile 過第一次** —— 看 pod log 是否一直在 `Failed to watch *v1.ConfigMap`。如果是,通常是 RBAC 問題:
   ```bash
   kubectl -n keda-system logs -l app.kubernetes.io/name=keda-deprecation-webhook --tail=20 | grep -E "forbidden|Failed to watch"
   ```
   [`charts/keda-deprecation-webhook/templates/rbac.yaml`](https://github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/charts/keda-deprecation-webhook/templates/rbac.yaml) 的 Role 必須允許 `configmaps: get/list/watch`(而且**不可加 `resourceNames`**,因為 RBAC 對 list/watch 不認 `resourceNames`)。

2. **cert-manager 還沒簽出 secret** —— `kdw-tls` Secret 不存在的話 pod 會 mount 失敗。
   ```bash
   kubectl -n keda-system get secret kdw-tls
   kubectl -n keda-system describe certificate kdw-serving-cert
   ```

3. **Image 還沒 load 進 kind**:
   ```bash
   docker exec keda-lab-worker ctr -n k8s.io image ls | grep keda-deprecation-webhook
   ```
   不在的話跑 `make install-webhook`(會重 build + load + restart)。

### 7.3 Pod 起來了但 admission 被 reject 即使 CM 設了 warn

**最可能的原因:CM watcher 跟 webhook 的 race**。修正過後不該再發生(readyz 已經 gate 在 generation > 0),但如果你看到還是有,再次確認:

```bash
# 兩個 replica 是否都 Ready?
kubectl -n keda-system get pods -l app.kubernetes.io/name=keda-deprecation-webhook
# 如果其中一個是 0/1,流量被導去那個 replica 才會中招
```

也檢查 webhook 是不是被分到 follower replica(以前的 bug):看兩個 pod 的 metric `config_generation` 是否都 > 0:

```bash
for pod in $(kubectl -n keda-system get pods -l app.kubernetes.io/name=keda-deprecation-webhook -o name); do
  kubectl -n keda-system exec $pod -- wget -qO- http://localhost:8080/metrics 2>/dev/null | grep "^keda_deprecation_config_generation"
done
```

(註:image 是 distroless,沒有 `wget`,實務上用 `kubectl run kdw-curl --rm --attach -i --restart=Never --image=curlimages/curl:8.10.1 --command -- curl -s http://...:8080/metrics`,`lab/scripts/verify-webhook.sh` 裡有現成 helper。)

### 7.4 Webhook 整個失聯怎麼辦

`failurePolicy: Ignore` —— **apiserver 不會等 KDW**,SO/SJ 會通過(可能漏網)。但:

1. Alert `KedaDeprecationWebhookDown` 5 分鐘後會 fire。
2. 等 KDW 恢復後,Controller path 會 list-watch 全部 SO/SJ,重新 emit gauge,漏網的 deprecation 在 dashboard 上會出現。
3. 短期內如果想暫時不放行 deprecation,可以**把 VWC 暫時 patch 成 `failurePolicy: Fail`**,但這樣全 cluster 的 SO/SJ apply 會卡住直到 KDW 修好。**不建議**作為常態。

---

## 8. Multi-cluster Rollout 流程

KDW 設計為支援 100+ 叢集 fleet,**enforcement level 跟 binary release 解耦**——你不用換 image,只要 `kubectl apply` 不同的 CM 就能切階段。

| 階段 | CM 內容 | 預期 |
|---|---|---|
| **Phase 0 — Lab 驗證** | `defaultSeverity: error`,`legacy-cpu` 例外為 `warn` | 本 repo 已驗證(`make verify-webhook` 全綠) |
| **Phase 1 — 全 fleet warn-mode** | `defaultSeverity: warn`(無 override) | 鋪 1–2 週,讓 dashboard 累積 inventory,各 team 自己看到自己的債並開始修 |
| **Phase 2 — Per-cluster enforcement** | 逐叢集(dev → staging → 低風險 prod → 高風險 prod)切 `defaultSeverity: error`,需要的 ns 加 override | 每個叢集的 CM 用 GitOps 管,revert commit 就立刻回退 |
| **Phase 3 — KEDA 2.18 升級** | 不動 KDW,升 KEDA | 每個叢集都等 `KedaDeprecationErrorViolationsPresent` 安靜了才升 |

關鍵特性:**每一步都可以幾秒內回退**(`kubectl apply` 上一份 CM)。不用重 build image、不用滾 Deployment。

---

## 9. 開發者參考:新增規則

當 KEDA 出現新的 deprecation(假設叫 KEDA002),把它變成可執行規則的步驟:

### 9.1 寫規則

`internal/rules/keda002.go`:

```go
package rules

import "fmt"

type SomeNewRule struct{}

func init() {
    Registry = append(Registry, &SomeNewRule{})
}

func (*SomeNewRule) ID() string                        { return "KEDA002" }
func (*SomeNewRule) BuiltinDefaultSeverity() Severity  { return SeverityError }

func (*SomeNewRule) Lint(t Target) []Violation {
    var out []Violation
    // 用 t.Triggers 做 lint,push Violation 到 out
    return out
}
```

### 9.2 寫 table-driven 測試

`internal/rules/keda002_test.go` —— 模仿 `keda001_test.go`,涵蓋:正向 case、負向 case、多 trigger 的 index 報對、邊界(空 Triggers、object-level 違規)。

### 9.3 規則自動註冊

`init()` 把規則塞進 `Registry`,**`webhook` 跟 `controller` 共用同一個 registry**,不需要任何別的接線。

### 9.4 跑既有測試確認框架沒被打壞

```bash
# 在 standalone repo (github.com/wys1203/keda-deprecation-webhook) 裡:
go test ./internal/...
```

### 9.5 操作員之後可以選擇性開啟新規則

KEDA002 上線後,operator 可以在 CM 加新一條規則:

```yaml
rules:
  - id: KEDA001
    defaultSeverity: error
  - id: KEDA002
    defaultSeverity: warn      # 新規則先用 warn 觀察一段
```

或者完全不寫 KEDA002,KDW 會 fallback 到 binary 預設(`SeverityError` for KEDA002)。**新規則不需要 CM 跟著一起升,只要 image 升上去就 active**,但 CM 仍可以蓋掉預設行為。

---

## 10. 附錄 A —— 檔案地圖

倉庫頂層分成兩塊:`scripts/`(orchestrator)、`lab/`(lab core)。
KDW 本元件已提取至獨立 repo：[github.com/wys1203/keda-deprecation-webhook](https://github.com/wys1203/keda-deprecation-webhook)。

KDW standalone repo 結構(v0.1.0):
- [`cmd/keda-deprecation-webhook/main.go`](https://github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/cmd/keda-deprecation-webhook/main.go) — 入口、manager wiring
- [`internal/rules/`](https://github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/internal/rules/) — Rule 介面 + KEDA001
- [`internal/config/`](https://github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/internal/config/) — schema / loader / resolver / store / watcher
- [`internal/metrics/`](https://github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/internal/metrics/) — Prometheus collectors
- [`internal/webhook/`](https://github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/internal/webhook/) — admission diff + handler
- [`internal/controller/`](https://github.com/wys1203/keda-deprecation-webhook/blob/v0.1.0/internal/controller/) — emitter + SO/SJ/namespace reconcilers
- `charts/keda-deprecation-webhook/` — Helm chart(取代舊 manifests/deploy/)
- `dashboard.json` — Grafana KEDA Deprecations(9 panels),lab 安裝時自動抓取

keda-labs repo 結構(本 repo):

```
keda-labs/
├── lab/                                           # lab core(KEDA + 監控 + demos)
│   ├── kind/cluster.yaml
│   ├── keda/values.yaml
│   ├── prometheus/values.yaml                     # 含 keda-deprecations alert group(原因見 §5.2)
│   ├── grafana/{dashboards,provisioning,values.yaml}
│   ├── charts/values-kdw-lab.yaml                 # Lab-specific KDW rule overrides
│   ├── manifests/{alert-stdout-sink.yaml, demo-cpu, demo-prom, legacy-cpu}
│   └── scripts/                                   # install-keda, install-monitoring, deploy-demo, install-webhook, verify-webhook, ...
│
├── scripts/                                       # 跨元件 orchestrator
│   ├── up.sh, delete-cluster.sh, status.sh, verify.sh, logs.sh, prereq-check.sh
│   ├── port-forward-{grafana,prometheus,alertmanager}.sh
│   └── lib.sh                                     # 定義 ROOT_DIR / LAB_DIR / KDW_VERSION
│
├── docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md
└── docs/superpowers/plans/2026-05-09-keda-deprecation-webhook.md
```

---

## 11. 附錄 B —— 常用指令速查

```bash
# 起整個 lab(含 KDW)
make up

# 只 build / install / verify webhook
make build-webhook
make install-webhook
make verify-webhook

# 觸發 reject 演示
make demo-deprecated

# 編 CM(熱重載)
kubectl -n keda-system edit cm keda-deprecation-webhook-config

# 看 KDW logs
kubectl -n keda-system logs -l app.kubernetes.io/name=keda-deprecation-webhook --tail=30 -f

# port-forward 直接看 metrics
kubectl -n keda-system port-forward svc/keda-deprecation-webhook 8080:8080
curl -s http://localhost:8080/metrics | grep keda_deprecation_

# 看現存違規(Grafana)
make grafana

# 砍掉重練
make recreate
```
