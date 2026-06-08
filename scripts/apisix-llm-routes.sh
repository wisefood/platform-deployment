#!/usr/bin/env bash
# Routing-as-code for the APISIX gateway: a single OpenAI-compatible endpoint
# (/v1/chat/completions) with model-aware admission control and provider proxying.
# Idempotent — PUTs a known route id, so re-running converges.
#
# The gateway itself (Deployment/Service/etcd/monitoring) is managed by Tanka via
# lib/apisix-gw.libsonnet. Routes live in etcd, so they are applied here through
# the Admin API rather than by `tk apply`.
#
# CLIENT CONTRACT (standard OpenAI):  POST /v1/chat/completions {"model","messages"}
#
# ADMISSION (serverless-pre-function, validated live on APISIX 3.16):
#   openrouter/*                      -> 503  (provider scaffolded, disabled)
#   anything not a known model        -> 400  (reject; no silent misroute)
#   gpt-oss* / llama* / *versatile /
#     mixtral* / gemma* / gpt-* /
#     o1-* / o3-*                     -> admitted to ai-proxy-multi
#
# PROVIDER SELECTION (ai-proxy-multi):
#   IMPORTANT LIMITATION — verified against this APISIX version: ai-proxy-multi
#   selects the upstream instance by BALANCER WEIGHT, not by the request's model.
#   It therefore CANNOT split gpt-* -> OpenAI vs llama-* -> Groq within one route.
#   We attempted dynamic per-request upstream selection via a serverless function
#   (apisix.upstream.set and pass_host:rewrite); both fail on 3.16 (500 / schema
#   rejection). So this route currently sends ALL admitted traffic to Groq
#   (weight 1), with OpenAI as a weight-0 standby instance.
#
#   To get TRUE model->provider splitting you must either upgrade to an APISIX
#   version whose ai-proxy-multi supports model routing, or front this with
#   separate per-provider routes selected by a client-supplied header (changes
#   the client contract). See the chat thread for the full investigation.
#
# Keys come from $ENV://GROQ_API_KEY / $ENV://OPENAI_API_KEY (extraEnvVars in
# lib/apisix-gw.libsonnet). A valid Groq key in secret groq-api-key/password is
# required for 200s; with an invalid key Groq returns 401 (routing still proven).
set -euo pipefail
ADMIN_URL="${ADMIN_URL:-http://apisix-admin.apisix.svc.cluster.local:9180}"
ADMIN_KEY="${ADMIN_KEY:?set ADMIN_KEY (APISIX admin API key)}"
api() { curl -sS -H "X-API-KEY: ${ADMIN_KEY}" "$@"; }

read -r -d '' ADMIT_FN <<'LUA' || true
return function(conf, ctx)
  local core = require("apisix.core")
  local b = core.request.get_body()
  local m = ""
  if b then local ok, j = pcall(core.json.decode, b); if ok and type(j)=="table" and j.model then m = j.model end end
  if m:find("^openrouter/") then
    return core.response.exit(503, {error = "openrouter provider not yet enabled"})
  end
  if not (m:find("^gpt%-oss") or m:find("^llama") or m:find("versatile$")
          or m:find("^mixtral") or m:find("^gemma")
          or m:find("^gpt%-") or m:find("^o1%-") or m:find("^o3%-")) then
    return core.response.exit(400, {error = "no provider configured for model: " .. m})
  end
end
LUA

PAYLOAD=$(ADMIT_FN="$ADMIT_FN" python3 - <<'PY'
import os, json
print(json.dumps({
  "name": "llm-chat",
  "uri": "/v1/chat/completions",
  "methods": ["POST"],
  "plugins": {
    "serverless-pre-function": {"phase": "access", "functions": [os.environ["ADMIT_FN"]]},
    "prometheus": {},
    "ai-proxy-multi": {
      "balancer": {"algorithm": "roundrobin"},
      "instances": [
        {"name": "groq", "provider": "openai-compatible", "weight": 1,
         "auth": {"header": {"Authorization": "Bearer $ENV://GROQ_API_KEY"}},
         "override": {"endpoint": "https://api.groq.com/openai/v1/chat/completions"}},
        {"name": "openai", "provider": "openai", "weight": 0,
         "auth": {"header": {"Authorization": "Bearer $ENV://OPENAI_API_KEY"}}}
      ]
    }
  }
}))
PY
)

echo ">> Creating/updating llm-chat route ..."
api -X PUT "${ADMIN_URL}/apisix/admin/routes/llm-chat" \
    -H 'Content-Type: application/json' -d "${PAYLOAD}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'value' in d else d)"

# Remove the legacy single-provider catch-all route (uri=/*, hardcoded key), if present.
echo ">> Removing legacy catch-all route (openai-v1-completions), if present ..."
api "${ADMIN_URL}/apisix/admin/routes" \
  | python3 -c '
import sys, json
for r in json.load(sys.stdin).get("list", []):
    v = r.get("value", {})
    if v.get("uri") == "/*" and v.get("name") == "openai-v1-completions":
        print(v.get("id"))
' | while read -r rid; do
      [ -n "$rid" ] && { echo "   deleting legacy route $rid"; api -X DELETE "${ADMIN_URL}/apisix/admin/routes/${rid}" >/dev/null; }
  done

echo ">> Done. Admitted models proxy to Groq; openrouter=503; unknown=400."
