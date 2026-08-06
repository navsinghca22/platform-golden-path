.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
include versions.env
export

.PHONY: help init up down bootstrap argocd-ui argocd-password open drift-demo validate lint status aws-creds bucket storage xp-status teardown-aws

help: ## Show this help
	@grep -hE "^[a-zA-Z_-]+:.*?## " $(MAKEFILE_LIST) \
		| awk -F":.*?## " "{printf \"  \\033[36m%-18s\\033[0m %s\\n\", \$$1, \$$2}"

init: ## Point the Argo CD Applications at your fork (run once, then commit)
	@./scripts/init-repo.sh

up: ## Create the kind cluster, install Argo CD, apply the root app
	@./scripts/bootstrap.sh

bootstrap: up

down: ## Delete the local cluster
	@./scripts/teardown.sh

argocd-ui: ## Port-forward the Argo CD UI to https://localhost:8081
	@echo "Argo CD UI -> https://localhost:8081  (self-signed cert; user: admin)"
	@kubectl -n argocd port-forward svc/argocd-server 8081:443

argocd-password: ## Print the initial admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d; echo

open: ## Print the sample app URL
	@echo "podinfo -> http://localhost:8080"

drift-demo: ## Break the cluster by hand and watch Argo CD heal it
	@./scripts/drift-demo.sh

status: ## Show Argo CD application state
	@kubectl -n argocd get applications -o wide

aws-creds: ## Create the AWS credentials Secret in-cluster from your local profile
	@./scripts/aws-credentials.sh

bucket: ## Ask the platform for a bucket (creates an ObjectStorage XR)
	@kubectl create -f examples/objectstorage.yaml

storage: ## Show ObjectStorage requests and the AWS buckets behind them
	@echo "--- ObjectStorage (what developers asked for) ---"
	@kubectl get objectstorages.platform.golden-path.io -A 2>/dev/null || echo "  none"
	@echo
	@echo "--- Bucket (what Crossplane created in AWS) ---"
	@kubectl get buckets.s3.aws.m.upbound.io -A 2>/dev/null || echo "  none"

xp-status: ## Show Crossplane providers and functions
	@kubectl get providers,functions 2>/dev/null || echo "crossplane not installed yet"

teardown-aws: ## Delete all cloud resources and VERIFY against the AWS API
	@./scripts/teardown-aws.sh

validate: ## Render every overlay and validate against the Kubernetes schema
	@./scripts/validate.sh

lint: ## Shellcheck the scripts
	@shellcheck scripts/*.sh
