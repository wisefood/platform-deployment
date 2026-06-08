#!/usr/bin/env bash
# Activate the APISIX prometheus plugin globally via the Admin API.
#
# The Helm values (apisix-values.yaml) load the plugin and expose the 9091
# metrics endpoint, but APISIX only emits per-request apisix_http_* metrics once
# the plugin is *activated* on traffic. This script does that with a global_rule.
#
# It is idempotent and non-destructive: it reads the existing global_rule "1",
# merges `prometheus: {}` into its plugins map (preserving any other global
# plugins already configured), and PUTs the result back. Re-running is a no-op.
#
# Usage (run against the cluster Admin API, e.g. via kubectl port-forward or a
# debug pod):
#   ADMIN_KEY=... ADMIN_URL=http://127.0.0.1:9180 ./scripts/apisix-enable-prometheus.sh
#
# Defaults target an in-cluster Admin API at apisix-admin.apisix:9180 with the
# chart's default admin key. Override ADMIN_KEY/ADMIN_URL for your environment.
set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://apisix-admin.apisix.svc.cluster.local:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
RULE_ID="${RULE_ID:-1}"

api() { curl -sS -H "X-API-KEY: ${ADMIN_KEY}" "$@"; }

echo ">> Reading existing global_rule '${RULE_ID}' from ${ADMIN_URL} ..."
existing="$(api "${ADMIN_URL}/apisix/admin/global_rules/${RULE_ID}" || true)"

# Extract the current plugins object (Admin API v3 wraps the object directly;
# older versions wrap under .node.value). Default to {} if the rule is absent.
current_plugins="$(printf '%s' "$existing" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("{}"); sys.exit(0)
# Not found / error responses have no usable plugins.
val = d.get("value", d.get("node", {}).get("value", {})) if isinstance(d, dict) else {}
print(json.dumps(val.get("plugins", {}) if isinstance(val, dict) else {}))
')"

echo ">> Existing global plugins: ${current_plugins}"

# Merge prometheus: {} without clobbering other global plugins.
merged="$(printf '%s' "$current_plugins" | python3 -c '
import sys, json
p = json.load(sys.stdin)
p.setdefault("prometheus", {})
print(json.dumps({"plugins": p}))
')"

echo ">> Writing merged global_rule: ${merged}"
api -X PUT "${ADMIN_URL}/apisix/admin/global_rules/${RULE_ID}" \
    -H 'Content-Type: application/json' \
    -d "${merged}" | python3 -m json.tool

echo ">> Done. Prometheus plugin activated globally (idempotent)."
