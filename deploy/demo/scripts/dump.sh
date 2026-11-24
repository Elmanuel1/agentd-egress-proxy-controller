#!/usr/bin/env bash
# Prints cluster state for a failed run. Never prints Secret data.
source "$(dirname "$0")/lib.sh"
set +e

kubectl get pods,svc,networkpolicy,hpa -A -o wide
kubectl get certificates,certificaterequests,issuers,clusterissuers -A
kubectl -n ws-demo describe deploy/proxy-env-demo
kubectl -n ws-demo describe certificate/iron-proxy-ca
kubectl -n ws-demo logs deploy/proxy-env-demo -c iron-proxy --tail=200
kubectl -n ws-demo logs deploy/proxy-env-demo -c config-reload --tail=50
kubectl -n upstream logs deploy/echo --tail=50
kubectl -n moto logs deploy/moto --tail=50
kubectl -n cert-manager logs deploy/cert-manager --tail=100
kubectl get events -A --sort-by=.lastTimestamp | tail -n 80
