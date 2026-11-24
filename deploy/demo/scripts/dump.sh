#!/usr/bin/env bash
# Prints cluster state for a failed run. Never prints Secret data.
source "$(dirname "$0")/lib.sh"
set +e

kubectl get pods,svc,networkpolicy,hpa,pdb -A -o wide
kubectl get certificates,certificaterequests,issuers,clusterissuers -A
kubectl -n ws-demo describe deploy/proxy-env-demo
kubectl -n ws-demo describe certificate/iron-proxy-ca
kubectl -n ws-demo logs deploy/proxy-env-demo -c iron-proxy --tail=200
kubectl -n ws-demo logs deploy/proxy-env-demo -c config-reload --tail=50
kubectl -n upstream logs deploy/echo --tail=50
kubectl -n moto logs deploy/moto --tail=50
kubectl -n observability logs -l app=otel-collector --tail=100 --prefix
kubectl -n otel-backend logs deploy/otel-backend --tail=20
kubectl -n kube-system logs deploy/metrics-server --tail=30
kubectl -n ws-demo describe hpa/proxy-env-demo
kubectl -n cert-manager logs deploy/cert-manager --tail=100
kubectl get events -A --sort-by=.lastTimestamp | tail -n 80
