SHELL := /bin/bash

CLUSTER_NAME ?= keda-lab
GRAFANA_PORT ?= 3000
PROMETHEUS_PORT ?= 9090
ALERTMANAGER_PORT ?= 9093
LOAD_DURATION ?= 90
LOAD_REPLICAS ?= 1

.DEFAULT_GOAL := help

.PHONY: help up down recreate status verify verify-monitoring demo load-test grafana prometheus alertmanager logs \
	prereqs create-cluster label-zones install-metrics-server install-prometheus \
	install-keda install-grafana install-monitoring

help:
	@printf "\nKEDA kind lab shortcuts\n\n"
	@printf "  %-22s %s\n" "make up" "Create the full lab environment"
	@printf "  %-22s %s\n" "make down" "Delete the kind cluster"
	@printf "  %-22s %s\n" "make recreate" "Recreate the cluster from scratch"
	@printf "  %-22s %s\n" "make status" "Show cluster and workload status"
	@printf "  %-22s %s\n" "make verify" "Run post-install verification checks"
	@printf "  %-22s %s\n" "make verify-monitoring" "Run monitoring stack verification checks"
	@printf "  %-22s %s\n" "make demo" "Deploy the CPU demo workload"
	@printf "  %-22s %s\n" "make load-test" "Run a temporary CPU spike against the demo"
	@printf "  %-22s %s\n" "make grafana" "Port-forward Grafana to localhost"
	@printf "  %-22s %s\n" "make prometheus" "Port-forward Prometheus to localhost"
	@printf "  %-22s %s\n" "make alertmanager" "Port-forward Alertmanager to localhost"
	@printf "  %-22s %s\n" "make logs" "Show key KEDA and demo logs"
	@printf "\nVariables: CLUSTER_NAME=%s GRAFANA_PORT=%s PROMETHEUS_PORT=%s ALERTMANAGER_PORT=%s LOAD_DURATION=%s LOAD_REPLICAS=%s\n\n" \
		"$(CLUSTER_NAME)" "$(GRAFANA_PORT)" "$(PROMETHEUS_PORT)" "$(ALERTMANAGER_PORT)" "$(LOAD_DURATION)" "$(LOAD_REPLICAS)"

up:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/up.sh

down:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/delete-cluster.sh

recreate:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/delete-cluster.sh
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/up.sh

status:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/status.sh

verify:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/verify.sh

verify-monitoring:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/verify-monitoring.sh

demo:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/deploy-demo.sh

load-test:
	@CLUSTER_NAME=$(CLUSTER_NAME) LOAD_DURATION=$(LOAD_DURATION) LOAD_REPLICAS=$(LOAD_REPLICAS) ./scripts/load-test.sh

grafana:
	@CLUSTER_NAME=$(CLUSTER_NAME) GRAFANA_PORT=$(GRAFANA_PORT) ./scripts/port-forward-grafana.sh

prometheus:
	@CLUSTER_NAME=$(CLUSTER_NAME) PROMETHEUS_PORT=$(PROMETHEUS_PORT) ./scripts/port-forward-prometheus.sh

alertmanager:
	@CLUSTER_NAME=$(CLUSTER_NAME) ALERTMANAGER_PORT=$(ALERTMANAGER_PORT) ./scripts/port-forward-alertmanager.sh

logs:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/logs.sh

prereqs:
	@./scripts/prereq-check.sh

create-cluster:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/create-cluster.sh

label-zones:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/label-zones.sh

install-metrics-server:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-metrics-server.sh

install-prometheus:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-prometheus.sh

install-keda:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-keda.sh

install-grafana:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-grafana.sh

install-monitoring:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-monitoring.sh
