# keda-labs

Reusable kind lab for KEDA experiments on Kubernetes `1.24.17` with:

- `1` control-plane and `3` worker nodes
- zone labels: `topology.kubernetes.io/zone=dc1|dc2|dc3`
- KEDA `2.18.3`
- Prometheus monitoring
- Grafana `11`
- CPU-based demo scaling scenario

## Prerequisites

- Docker
- kind
- kubectl
- Helm
- make

## Quick start

```bash
make up
make status
make load-test
make grafana
```

Grafana is exposed locally through `kubectl port-forward` at `http://localhost:3000`.

## Common commands

```bash
make help
make recreate
make demo
make verify
make logs
make down
```

## Notes

- `make up` installs metrics-server, Prometheus, Grafana, and KEDA, then deploys the CPU demo workload.
- `make load-test` temporarily patches the demo container into a busy loop so KEDA can scale it up.
- `make grafana` expects the Grafana release in the `monitoring` namespace and uses the default service name created by the Helm chart.
