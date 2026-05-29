# APISIX AI Gateway — `apisix.libsonnet` design

Date: 2026-05-29

## Purpose

Add a libsonnet component that manifests an **internal-only APISIX AI gateway** for the
WiseFood platform deployment. The gateway is an **egress mediator** between in-cluster
applications and external LLM providers. Apps (foodscholar, recipewrangler, foodchat)
send OpenAI-compatible chat-completion requests to the gateway with **no provider API
key**. The gateway selects a provider by the request's `model` field, injects the
provider key, applies prompt-engineering plugins and token quotas, and forwards to the
external provider (Groq primary, OpenAI fallback).

It is **not** public-facing: it is reached only at the internal cluster DNS name
`http://ai-gateway:9080`. It is therefore **not** added to `ingress.libsonnet`.

## Scope

- In scope: the `apisix.libsonnet` file (declarative APISIX deployment + config), and the
  supporting `pim.libsonnet` additions (port + image entry).
- Out of scope (this iteration): wiring the component into `generate.libsonnet`'s
  component list. The lib is written only; the user will add it to the manifest list
  separately.
- Out of scope: etcd-backed dynamic config, APISIX ingress controller / CRDs, public
  ingress for the gateway.

## Mode

**Standalone declarative.** APISIX runs as a data-plane reading static config from a
mounted ConfigMap. No etcd, no Admin API writes. All routes/upstreams/plugins are
defined declaratively in libsonnet and rendered into `apisix.yaml`. This matches the
project's GitOps style and keeps config diffable.

## Components

All exposed under `generate_manifest(pim, config)`, following the existing lib convention
(`k.libsonnet` aliases, `withEnvMap`, `envSource.secretKeyRef`, `svcs.serviceFor`).

### 1. `configmap`
A `ConfigMap` carrying two files:

- **`config.yaml`** — APISIX instance settings:
  - `deployment.role: data_plane`
  - `deployment.role_data_plane.config_provider: yaml` (standalone mode)
  - admin API disabled
  - listen on port 9080 (HTTP)
- **`apisix.yaml`** — the declarative routes/upstreams/plugins (see below). Ends with the
  required `#END` sentinel line that APISIX standalone mode expects.

### 2. `deployment`
- Name: `ai-gateway`
- Image: `pim.images.APISIX` (new pim entry)
- Port: `pim.ports.APISIX` (9080), named port `gw`
- Mounts the ConfigMap at `/usr/local/apisix/conf/` so both `config.yaml` and
  `apisix.yaml` are read by APISIX.
- Provider API keys injected as env vars via `envSource.secretKeyRef`:
  - `GROQ_API_KEY` ← `config.secrets.api.groq_api_key` (reuses existing secret)
  - `OPENAI_API_KEY` ← `config.secrets.api.openai_api_key` (new secret, to be added to
    `example_config.yaml` / cluster secrets by the user)
- `apisix.yaml` references these with APISIX's `$ENV://GROQ_API_KEY` interpolation, so
  keys never appear in the rendered ConfigMap.
- Pod labels follow convention:
  `app.kubernetes.io/name: ai-gw`, `app.kubernetes.io/component: ai-gateway`.

### 3. `svc`
`svcs.serviceFor(self.deployment)` → stable `ai-gateway` service. App-facing endpoint:
`http://ai-gateway:9080/v1/chat/completions`.

### 4. `pim.libsonnet` additions
- `ports.APISIX: 9080`
- `images.APISIX` entry (referenced like other `pim.images.*`).

## Data-driven provider/model configuration

The top of the lib defines a **data block** so adding a model/provider is a one-line
edit (consistent with how the other libs stay declarative):

```jsonnet
local providers = {
  groq: {
    endpoint: "https://api.groq.com/openai/v1/chat/completions",
    auth_env: "GROQ_API_KEY",
    weight: 100,
    priority: 1,          // primary
  },
  openai: {
    endpoint: "https://api.openai.com/v1/chat/completions",
    auth_env: "OPENAI_API_KEY",
    weight: 0,
    priority: 0,          // fallback
  },
};

// model name -> provider key (drives ai-proxy-multi model routing)
local model_routing = {
  "llama-3.3-70b-versatile": "groq",
  "llama-3.1-8b-instant":    "groq",
  "gpt-4o-mini":             "openai",
};
```

The `ai-proxy-multi` instances are generated from `providers`; the route's model routing
from `model_routing`.

## The `apisix.yaml` route

Single OpenAI-compatible route:

- **Path/method:** `POST /v1/chat/completions`
- **Plugin `ai-proxy-multi`:**
  - **instances** for `groq` and `openai`, each with
    `auth.header.Authorization: "Bearer $ENV://<auth_env>"` and the provider override
    endpoint.
  - **Provider steering & fallback:** instance `weight` + `priority` with passive health
    checks, so OpenAI (priority 0, fallback) takes over when Groq (priority 1, primary)
    fails. Groq carries all weight under normal operation.
  - **Model-based routing:** request `model` field maps to the provider per
    `model_routing`.
- **Plugin `ai-prompt-decorator`:** prepend a shared system message (default prompt
  defined in the data block, overridable).
- **Plugin `ai-prompt-guard`:** regex deny rules on prompt content (default rules in the
  data block).
- **Plugin `ai-rate-limiting`:** token-based quota (limit + time window from the data
  block).
- **Plugin `limit-count`:** request-rate cap as a coarse backstop.

Prompt-template/guard/quota defaults live in the same top-of-file data block so they are
easy to tune in one place.

## Error handling / operational notes

- If Groq is unhealthy, `ai-proxy-multi` passive health checks fail it out and route to
  the OpenAI fallback instance.
- Keys are only ever present as env vars at runtime; the rendered ConfigMap contains
  `$ENV://` placeholders, not secrets.
- Standalone mode requires a pod restart to pick up `apisix.yaml` changes (acceptable —
  config changes go through the normal manifest re-apply).

## Testing / verification

- Render the lib through the project's jsonnet tooling (`wisefoodctl.py` / the generate
  path) in isolation to confirm it produces valid YAML (deployment, configmap, service).
- Lint the embedded `apisix.yaml` for valid APISIX standalone structure (route +
  upstream + plugins, trailing `#END`).
- No live provider calls in this iteration — runtime verification happens after the user
  wires it into the manifest and supplies the OpenAI secret.

## Open items resolved

1. OpenAI is the **live** fallback provider (confirmed).
2. The lib is **written only**; not wired into `generate.libsonnet` (confirmed).
