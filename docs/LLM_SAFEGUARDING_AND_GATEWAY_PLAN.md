# LLM safeguarding, PII redaction, and finishing the APISIX AI gateway

A plan built from what is actually deployed, not from what the design docs say.
Every claim below was checked against the manifests and code on 2026-09-07.

---

## 0. What is actually there today

Three separate things exist, and only one of them is live.

| Artefact | State | Notes |
|---|---|---|
| **APISIX ingress** (`lib/apisix-gw.libsonnet`) | **Live**, wf-prod | etcd-backed, Admin API on `:9180`, ClusterIP. Routes are pushed via the Admin API, not declared in Jsonnet. |
| **`llm-chat` route** (`scripts/apisix-llm-routes.sh`) | **Pushed by script** — presence in prod etcd unverified | `POST /v1/chat/completions` → `ai-proxy-multi`: Groq weight 1, OpenAI **weight 0**. Prompt-guard (3 jailbreak patterns), prompt-decorator, 100k tokens/min. Provider key injected server-side. **No client auth.** |
| **`ai-gateway`** (`lib/apisix.libsonnet`) | **Dead** — imported nowhere | A second, yaml-configured APISIX with a fuller `ai-proxy-multi` (real priority failover, `ai-rate-limiting` per instance). Never deployed. |
| **`llm-router.lua`** | **Abandoned WIP** — its own header says so | Model→provider routing; crashes in the balancer on this APISIX. Not wired. |
| **FoodChat / FoodScholar LLM calls** | **Bypass all of it** | Both construct `ChatGroq(...)` with no `base_url` → straight to `api.groq.com`. Nothing has ever exercised the gateway. |

Two corrections to things said earlier in this work:

- The `llm-chat` route sets **no `options.model`** on its instances, so the request's `model` **passes through**. FoodScholar's per-mode model choice (gpt-oss-20b vs 120b) survives the gateway. The real limitation is *provider* selection: `ai-proxy-multi` picks an instance by weight, so it cannot send `gpt-*` to OpenAI and `llama-*` to Groq inside one route.
- OpenAI at **weight 0** is not a fallback. Roundrobin never selects it. Today there is **no failover** if Groq rate-limits.

Verify what prod etcd holds before anything else:

```bash
kubectl --context k8s-w -n apisix exec deploy/apisix -- \
  curl -s -H "X-API-KEY: $ADMIN_KEY" http://127.0.0.1:9180/apisix/admin/routes | jq '.list[].value | {name, uri, plugins: (.plugins|keys)}'
```

---

## 1. Safeguarding — ranked by what would actually hurt

### 1.1 CRITICAL — the APISIX dashboard is on the internet at chart defaults

`apisix-dashboard-embed.yaml` publishes `apisix.wisefood.gr` → `apisix-dashboard:80` with **no auth annotation**. No dashboard values file exists, so the dashboard runs at upstream chart defaults — which means the default dashboard login unless something outside this repo changed it. The dashboard holds the Admin API key and sits inside the pod network, so the Admin API's `127.0.0.1/24` allow-list does not protect it. Anyone who reaches that host and guesses the default login can rewrite every production route.

Also: `admin.credentials.admin` is the chart's **published default key** (`edd1c9f0…`), overridden nowhere.

**Do first, before any LLM work:**
1. Take the dashboard ingress down (`kubectl delete ingress apisix-dashboard -n apisix`) or put it behind Keycloak (`oauth2-proxy` / nginx `auth-url`). It exists for Grafana embedding; that can be re-done behind auth.
2. Rotate the Admin API key: set `admin.credentials.admin` from a secret (`secretName`/`secretAdminKey` are supported by the chart), regenerate, redeploy, update `ADMIN_KEY` wherever the route script runs.
3. Set dashboard credentials explicitly, or disable the dashboard entirely — `enable_admin_ui: false`. Route pushes already go through `curl` against the Admin API; the UI is not needed.

Zero downtime: none of this touches the data plane.

### 1.2 HIGH — the `llm-chat` route has no client auth

Once services route through it, anything in the cluster that can reach `apisix:9080` can spend the Groq and OpenAI keys. Add `key-auth` with one consumer per service (`foodchat`, `foodscholar`), keys from secrets. Clients send `apikey: <key>`. Do this **in the same Admin API PUT** that services start using, so there is no window with an open route.

### 1.3 HIGH — no real failover

Give OpenAI weight 1 and priority 0 (Groq priority 1) with `fallback_strategy: ["http_429","http_5xx","rate_limiting"]`, exactly as the dead `apisix.libsonnet` already specifies. That file is the correct design; lift its route block into the script.

**Caveat:** failover to OpenAI sends the conversation to a second processor. That is a DPIA line. If that is not acceptable, the fallback should be a *second Groq model*, not OpenAI.

### 1.4 MEDIUM — input safety

What exists: `ai-prompt-guard` with three regexes (`ignore previous instructions`, `disregard above`, `you are now DAN`). That is a demo, not a control. There is no dedicated safety layer in either service.

Two layers, cheap one first:

- **Deterministic PII redaction** — `foodchat/src/pii.py` is written (uncommitted, off behind `PII_REDACTION`). Emails, phones, IBAN (mod-97), cards (Luhn), IPs, addresses. Exact, free, auditable. **Cannot catch names.** Verified it leaves "allergic to peanuts, take metformin" alone — that is the medical content the product exists to use. One bug to fix: bare 16-digit runs match `PHONE`.
- **`ai-request-rewrite`** (already enabled in the plugin list) — sends the body to an LLM with a redaction prompt and forwards the rewritten body. Catches names and free-form disclosure. Costs: **every turn becomes two LLM calls**; non-deterministic; can be argued out of it by the text it is redacting; and **the failure mode is the whole question** — on error, does the raw text go through (fail-open) or does the turn fail (fail-closed)?

**The decision that matters:** which model does the rewriting. Sending health chat to Groq *to remove PII* means the unredacted text reaches a third party anyway — the redaction happens after the transfer it was meant to prevent. It is only worth doing with an **in-cluster model**, and **there is none** (no Ollama/vLLM/TGI anywhere in the manifests). Until there is, `ai-request-rewrite` is self-defeating and should stay off.

Expand `ai-prompt-guard` instead — it is deterministic, local, free — and move the patterns into Jsonnet so they are reviewed, not hidden in a shell heredoc.

### 1.5 MEDIUM — spend

`ai-rate-limiting` is one global 100k tokens/min. Move to **per-consumer** quotas once `key-auth` exists, so FoodScholar's enrichment worker cannot starve FoodChat. Keep the services' `wf_telemetry` as the **authoritative token count**; set `logging.summaries: false` on the route so the gateway does not produce a second, disagreeing counter.

---

## 2. Finishing the gateway — without bringing production down

The services are the only clients. Nothing user-facing changes until step 4, and every step is reversible by unsetting one env var.

| Step | Change | Blast radius | Rollback |
|---|---|---|---|
| 1 | 1.1 above (dashboard, admin key) | none on data plane | n/a |
| 2 | Re-push `llm-chat` via the script with: `key-auth` + two consumers, OpenAI weight 1 / priority 0 with `fallback_strategy`, prompt-guard patterns expanded, `logging.summaries: false`. **Idempotent PUT by id** — the route is replaced atomically. | none — nothing calls it yet | re-run script with old payload |
| 3 | Add `LLM_BASE_URL` + `LLM_GATEWAY_KEY` env to FoodChat and FoodScholar. Code: `ChatGroq(..., base_url=os.getenv("LLM_BASE_URL") or None, default_headers={"apikey": key} if key else None)`. **Unset → identical to today.** Pin `langchain-groq` in FoodChat (`>=1.0.0` is a floating bound; FoodScholar is `==0.3.8`). | none until env is set | unset the env |
| 4 | Set `LLM_BASE_URL` on **FoodScholar first** (lower traffic, two models, exercises pass-through). Watch: `route_performance` for `/foodscholar/*` latency, Langfuse for the same `model` values, `llm_usage.provider` still `groq`. | FoodScholar only | unset, restart |
| 5 | Same for FoodChat. | FoodChat | unset, restart |
| 6 | Delete `lib/apisix.libsonnet` and `llm-router.lua` after lifting the route block from the former. Two designs for one gateway is how this got half-finished. | none | git |

**What to verify at step 4** — in the console, not by hand: the session page's model calls still show `provider: groq` and the same models; Service health shows the FoodScholar routes' p95 within a few tens of ms of before (one extra in-cluster hop); Browser errors shows no new `http` group. If Groq is down, a 429 test (`ai-rate-limiting` at a tiny quota in a non-prod route) should produce OpenAI in Langfuse.

**Model changes after this**: a Jsonnet/script edit and one Admin API PUT — no service restart. Per-feature model choice stays in the services because the model passes through.

---

## 3. What this plan does not do

- No in-cluster LLM. Until one exists, LLM-based redaction is a transfer, not a protection.
- No content moderation beyond prompt-guard. `ai-aws-content-moderation` / `ai-aliyun-…` are enabled in the plugin list but would send every message to AWS/Aliyun — same objection.
- Does not fix `llm-router.lua`. The provider-split it attempted is available today as **two routes with two URIs** (`/v1/groq/…`, `/v1/openai/…`) if ever needed; the client picks. Simpler than a broken Lua balancer.
