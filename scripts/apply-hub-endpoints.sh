#!/usr/bin/env bash
set -euo pipefail

readonly hub_node_name="${HUB_NODE_NAME:-hub-control-plane}"
readonly downstream_context="${DOWNSTREAM_CONTEXT:-kind-downstream}"
readonly endpoint_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../observability/downstream/hub-endpoint" && pwd)"

hub_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${hub_node_name}")"
if [[ -z "${hub_ip}" ]]; then
  printf 'Could not determine a Docker-network IP for %s.\n' "${hub_node_name}" >&2
  exit 1
fi

for file in "${endpoint_directory}"/*-endpoint-slice.yaml; do
  service_name="$(basename "${file}" -endpoint-slice.yaml)"

  case "${service_name}" in
    mimir)
      ports='  - name: http
    protocol: TCP
    port: 30090'
      ;;
    loki)
      ports='  - name: http
    protocol: TCP
    port: 30100'
      ;;
    tempo)
      ports='  - name: http
    protocol: TCP
    port: 30200
  - name: otlp-grpc
    protocol: TCP
    port: 30417'
      ;;
    *)
      printf 'Unsupported hub service: %s\n' "${service_name}" >&2
      exit 1
      ;;
  esac

  kubectl --context "${downstream_context}" -n observability apply -f - <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: hub-${service_name}
  labels:
    kubernetes.io/service-name: hub-${service_name}
addressType: IPv4
ports:
${ports}
endpoints:
  - addresses:
      - ${hub_ip}
EOF
done

printf 'Applied hub EndpointSlices with hub IP %s.\n' "${hub_ip}"
