# APISIX AI Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `lib/apisix.libsonnet`, an internal-only APISIX AI gateway that mediates LLM egress from in-cluster apps to Groq (primary) with OpenAI failover, in standalone declarative mode.

**Architecture:** A single `generate_manifest(pim, config)` lib produces a ConfigMap (`config.yaml` + `apisix.yaml`), a `ai-gateway` Deployment that mounts it and injects provider keys as env vars, and a Service. The route `/v1/chat/completions` uses `ai-proxy-multi` with priority-based failover (Groq primary, OpenAI fallback), plus `ai-prompt-decorator`, `ai-prompt-guard`, `ai-rate-limiting`, and `limit-count`. Provider/prompt/quota settings live in a data block at the top of the file so they are one-line edits.

**Tech Stack:** Jsonnet (Tanka/`k.libsonnet`), Apache APISIX `3.14.1-debian` standalone, Kubernetes (Deployment/ConfigMap/Service).

---

## Verification approach

This is a deployment-manifest library, not application code with a unit-test harness. "Tests" here = **rendering the lib through jsonnet and asserting on the produced manifest**, plus **validating the embedded `apisix.yaml` is well-formed**. Each task follows: write a render assertion → run it, watch it fail → implement → run it, watch it pass → commit.

The render harness is a throwaway jsonnet file evaluated with the project's vendored libs. Confirm the jsonnet binary first.

- [ ] **Step 0: Tooling (already confirmed)**

The repo uses Tanka (`tk` at `/usr/local/bin/tk`) and `jb`. `lib/k.libsonnet` imports
`github.com/jsonnet-libs/k8s-libsonnet/1.32/main.libsonnet` from `vendor/`. The render
command **`RENDER`** used throughout this plan is:

```
tk eval --jpath lib --jpath vendor <file-or--e-expr>
```

If `tk eval` rejects a bare expression without an environment, fall back to go-jsonnet if
present (`jsonnet -J lib -J vendor`). Confirm with:
`tk eval --jpath lib --jpath vendor -e '(import "pim.libsonnet").ports.REDIS'` → `6379`.

---

## Task 1: Add APISIX port and image to the platform-independent model

**Files:**
- Modify: `lib/pim.libsonnet` (ports block ~line 14-32; add an images reference convention used by other libs via `pim.images.*`)

Note: other libs reference `pim.images.APISIX`, but the `images` map is supplied by the environment/config layer (see how `pim.images.FOODSCHOLAR` etc. are consumed — they are not defined in `pim.libsonnet` itself). Only the **port** belongs in `pim.libsonnet`. The image tag is pinned in the lib's data block (Task 2) as a default, overridable by `pim.images.APISIX` if present.

- [ ] **Step 1: Add the APISIX port**

In `lib/pim.libsonnet`, inside the `ports:` object, add a trailing entry after `FOODCHAT: 8000`:

```jsonnet
    FOODCHAT: 8000,
    APISIX: 9080
```

(Add the comma after `8000` and the new line.)

- [ ] **Step 2: Render pim to verify it parses**

Create `/tmp/render_pim.jsonnet`:

```jsonnet
local pim = import "pim.libsonnet";
{ apisix_port: pim.ports.APISIX }
```

Run: `RENDER -J lib /tmp/render_pim.jsonnet`
Expected: `{ "apisix_port": 9080 }`

- [ ] **Step 3: Commit**

```bash
git add lib/pim.libsonnet
git commit -m "Add APISIX gateway port (9080) to platform-independent model"
```

---

## Task 2: Create the lib skeleton with the data block and config.yaml ConfigMap

**Files:**
- Create: `lib/apisix.libsonnet`
- Test: `/tmp/render_apisix.jsonnet` (throwaway render harness)

- [ ] **Step 1: Write the render assertion (failing — file does not exist yet)**

Create `/tmp/render_apisix.jsonnet`:

```jsonnet
local apisix = import "apisix.libsonnet";
local pim = import "pim.libsonnet";
local config = {
  namespace: "wisefood-dev",
  secrets: { api: { groq_api_key: "groq-api-key", openai_key: "openai-key" } },
};
local m = apisix.generate_manifest(pim, config);
{
  has_configmap: std.objectHas(m, "configmap"),
  has_deployment: std.objectHas(m, "deployment"),
  has_svc: std.objectHas(m, "svc"),
  cm_kind: m.configmap.kind,
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `RENDER -J lib /tmp/render_apisix.jsonnet`
Expected: FAIL — `RUNTIME ERROR: couldn't open import "apisix.libsonnet"`

- [ ] **Step 3: Create `lib/apisix.libsonnet` with imports, data block, and the config.yaml ConfigMap**

```jsonnet

local k = import "k.libsonnet";
local svcs = import "services.libsonnet";

local deploy = k.apps.v1.deployment;
local container = k.core.v1.container;
local containerPort = k.core.v1.containerPort;
local volumeMount = k.core.v1.volumeMount;
local vol = k.core.v1.volume;
local cmap = k.core.v1.configMap;
local envSource = k.core.v1.envVarSource;

{
    // ----------------------------------------------------------------------
    // Tunables: providers, prompt shaping, and quotas live here so adding or
    // changing behavior is a one-line edit.
    // ----------------------------------------------------------------------
    local apisix_image = "apache/apisix:3.14.1-debian",

    // Priority-based failover. ai-proxy-multi does NOT route by the request's
    // model field; each instance forces its own options.model. Higher priority
    // wins; lower priority is the fallback when the primary fails / is rate-limited.
    local providers = [
        {
            name: "groq-primary",
            provider: "openai-compatible",   // Groq exposes an OpenAI-compatible API
            endpoint: "https://api.groq.com/openai/v1/chat/completions",
            auth_env: "GROQ_API_KEY",
            model: "llama-3.3-70b-versatile",
            weight: 1,
            priority: 1,
        },
        {
            name: "openai-fallback",
            provider: "openai",
            endpoint: "https://api.openai.com/v1/chat/completions",
            auth_env: "OPENAI_API_KEY",
            model: "gpt-4o-mini",
            weight: 1,
            priority: 0,
        },
    ],

    // Prompt engineering defaults.
    local prompt_decorator_prepend = [
        { role: "system", content: "You are an assistant for the WiseFood platform. Be concise and factual." },
    ],
    // ai-prompt-guard deny patterns (regex). Empty list disables guarding.
    local prompt_guard_deny = [],

    // Quotas.
    local token_quota = { limit: 100000, time_window: 60 },   // tokens per window (seconds)
    local request_quota = { count: 120, time_window: 60 },    // requests per window (seconds)

    // ----------------------------------------------------------------------
    // config.yaml: APISIX standalone data-plane settings.
    // ----------------------------------------------------------------------
    local config_yaml = std.manifestYamlDoc({
        deployment: {
            role: "data_plane",
            role_data_plane: { config_provider: "yaml" },
        },
        apisix: {
            // Expose only the data-plane HTTP listener; no admin API in standalone.
            node_listen: 9080,
            enable_admin: false,
        },
    }),

    generate_manifest(pim, config): {

        configmap: cmap.new("ai-gateway-config")
            + cmap.withData({
                "config.yaml": config_yaml,
                "apisix.yaml": "",   // filled in Task 3
            }),
    },
}
```

- [ ] **Step 4: Run the render to verify the ConfigMap exists (deployment/svc still missing → partial)**

Run: `RENDER -J lib /tmp/render_apisix.jsonnet`
Expected: FAIL on `has_deployment` / `cm_kind` access — but no import error. Specifically `m.configmap.kind` should evaluate to `"ConfigMap"`. The `has_deployment`/`has_svc` fields render `false`. This confirms the ConfigMap branch works before adding the rest.

To check just the ConfigMap in isolation, run:
`RENDER -J lib -e 'local a=import "apisix.libsonnet"; local p=import "pim.libsonnet"; a.generate_manifest(p, {namespace:"x",secrets:{api:{groq_api_key:"g",openai_key:"o"}}}).configmap.kind'`
Expected: `"ConfigMap"`

- [ ] **Step 5: Commit**

```bash
git add lib/apisix.libsonnet
git commit -m "Add APISIX gateway lib skeleton with data block and config.yaml ConfigMap"
```

---

## Task 3: Build the apisix.yaml route (ai-proxy-multi + prompt + quota plugins)

**Files:**
- Modify: `lib/apisix.libsonnet` (add an `apisix_yaml` local generated from the data block; wire it into the ConfigMap)

- [ ] **Step 1: Add the route-building locals above `config_yaml`**

Insert into the top-level object (alongside the other `local`s), after `request_quota`:

```jsonnet
    // Build ai-proxy-multi instances from the providers data block.
    local proxy_instances = [
        {
            name: p.name,
            provider: p.provider,
            weight: p.weight,
            priority: p.priority,
            auth: { header: { Authorization: "Bearer $ENV://" + p.auth_env } },
            options: { model: p.model },
            override: { endpoint: p.endpoint },
        }
        for p in providers
    ],

    local route_plugins =
        {
            "ai-proxy-multi": {
                fallback_strategy: ["rate_limiting"],
                balancer: { algorithm: "roundrobin" },
                instances: proxy_instances,
                logging: { summaries: true },
            },
            "limit-count": {
                count: request_quota.count,
                time_window: request_quota.time_window,
                key_type: "var",
                key: "remote_addr",
                rejected_code: 429,
            },
        }
        + (if std.length(prompt_decorator_prepend) > 0
           then { "ai-prompt-decorator": { prepend: prompt_decorator_prepend } }
           else {})
        + (if std.length(prompt_guard_deny) > 0
           then { "ai-prompt-guard": { match_failure_response: "Request blocked by prompt guard.", deny_patterns: prompt_guard_deny } }
           else {}),

    // apisix.yaml MUST end with a literal "#END" line or APISIX won't load it.
    local apisix_yaml =
        std.manifestYamlDoc({
            routes: [
                {
                    uri: "/v1/chat/completions",
                    methods: ["POST"],
                    plugins: route_plugins,
                },
            ],
        })
        + "\n#END\n",
```

Note on `ai-rate-limiting`: token-quota enforcement is configured **inside**
`ai-proxy-multi` via `fallback_strategy: ["rate_limiting"]` together with per-instance
token limits. The standalone `ai-rate-limiting` plugin is added per-instance through the
proxy in current APISIX; for this iteration the request-rate backstop (`limit-count`) is
the enforced quota and `token_quota` is reserved in the data block for the per-instance
limit wiring. If a hard token cap is required now, add `limit: token_quota.limit` to each
entry of `proxy_instances`. (Left out by default to avoid over-restricting until tuned.)

- [ ] **Step 2: Wire `apisix_yaml` into the ConfigMap**

Change the ConfigMap data:

```jsonnet
            + cmap.withData({
                "config.yaml": config_yaml,
                "apisix.yaml": apisix_yaml,
            }),
```

- [ ] **Step 3: Update the render harness to assert on the route content**

Replace `/tmp/render_apisix.jsonnet` with:

```jsonnet
local apisix = import "apisix.libsonnet";
local pim = import "pim.libsonnet";
local config = {
  namespace: "wisefood-dev",
  secrets: { api: { groq_api_key: "groq-api-key", openai_key: "openai-key" } },
};
local m = apisix.generate_manifest(pim, config);
local ay = m.configmap.data["apisix.yaml"];
{
  cm_kind: m.configmap.kind,
  has_route_path: std.length(std.findSubstr("/v1/chat/completions", ay)) > 0,
  has_ai_proxy_multi: std.length(std.findSubstr("ai-proxy-multi", ay)) > 0,
  has_groq: std.length(std.findSubstr("api.groq.com", ay)) > 0,
  has_openai: std.length(std.findSubstr("api.openai.com", ay)) > 0,
  has_env_groq: std.length(std.findSubstr("$ENV://GROQ_API_KEY", ay)) > 0,
  ends_with_end: std.length(std.findSubstr("#END", ay)) > 0,
}
```

- [ ] **Step 4: Run it to verify all assertions are true**

Run: `RENDER -J lib /tmp/render_apisix.jsonnet`
Expected:
```json
{
   "cm_kind": "ConfigMap",
   "ends_with_end": true,
   "has_ai_proxy_multi": true,
   "has_env_groq": true,
   "has_groq": true,
   "has_openai": true,
   "has_route_path": true
}
```

- [ ] **Step 5: Validate the embedded apisix.yaml is well-formed YAML**

Run:
```bash
RENDER -J lib -e 'local a=import "apisix.libsonnet"; local p=import "pim.libsonnet"; a.generate_manifest(p, {namespace:"x",secrets:{api:{groq_api_key:"g",openai_key:"o"}}}).configmap.data["apisix.yaml"]' | python3 -c 'import sys,yaml; t=sys.stdin.read().strip().strip("\"").encode().decode("unicode_escape"); docs=[d for d in yaml.safe_load_all(t.replace("#END","")) ]; print("routes:", len(docs[0]["routes"]))'
```
Expected: `routes: 1` (no YAML parse exception). If the unicode-escape handling is awkward, instead pipe the rendered string to a file and run `yamllint`/`python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))'` on the de-quoted content.

- [ ] **Step 6: Commit**

```bash
git add lib/apisix.libsonnet
git commit -m "Add APISIX ai-proxy-multi route with prompt and rate-limit plugins"
```

---

## Task 4: Add the Deployment (mount ConfigMap, inject provider keys)

**Files:**
- Modify: `lib/apisix.libsonnet` (add `deployment` to the returned manifest)

- [ ] **Step 1: Add the deployment to `generate_manifest`**

Add after `configmap:` (note the trailing comma on `configmap`):

```jsonnet
        deployment: deploy.new(name="ai-gateway", containers=[
            container.new("apisix", apisix_image)
            + container.withImagePullPolicy("IfNotPresent")
            + container.withEnvMap({
                GROQ_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.groq_api_key) + envSource.secretKeyRef.withKey("password"),
                OPENAI_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.openai_key) + envSource.secretKeyRef.withKey("password"),
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.APISIX, "gw"),
            ])
            + container.withVolumeMounts([
                volumeMount.new("apisix-config", "/usr/local/apisix/conf/config.yaml", true)
                + volumeMount.withSubPath("config.yaml"),
                volumeMount.new("apisix-config", "/usr/local/apisix/conf/apisix.yaml", true)
                + volumeMount.withSubPath("apisix.yaml"),
            ])
            + container.readinessProbe.tcpSocket.withPort(pim.ports.APISIX)
            + container.readinessProbe.withInitialDelaySeconds(5)
            + container.readinessProbe.withPeriodSeconds(10),
        ],
        podLabels={
            'app.kubernetes.io/name': 'ai-gw',
            'app.kubernetes.io/component': 'ai-gateway',
        })
        + deploy.spec.template.spec.withVolumes([
            vol.fromConfigMap("apisix-config", "ai-gateway-config"),
        ]),
```

Note: two `subPath` mounts from one ConfigMap volume place both files into APISIX's
`conf/` directory without clobbering the image's other conf files.

- [ ] **Step 2: Extend the render harness to assert on the deployment**

Append these fields to the object in `/tmp/render_apisix.jsonnet`:

```jsonnet
  dep_kind: m.deployment.kind,
  dep_name: m.deployment.metadata.name,
  dep_image: m.deployment.spec.template.spec.containers[0].image,
  dep_port: m.deployment.spec.template.spec.containers[0].ports[0].containerPort,
  mount_count: std.length(m.deployment.spec.template.spec.containers[0].volumeMounts),
```

- [ ] **Step 3: Run it to verify**

Run: `RENDER -J lib /tmp/render_apisix.jsonnet`
Expected additions:
```json
   "dep_image": "apache/apisix:3.14.1-debian",
   "dep_kind": "Deployment",
   "dep_name": "ai-gateway",
   "dep_port": 9080,
   "mount_count": 2,
```

- [ ] **Step 4: Commit**

```bash
git add lib/apisix.libsonnet
git commit -m "Add ai-gateway Deployment mounting APISIX config and injecting provider keys"
```

---

## Task 5: Add the Service and finalize

**Files:**
- Modify: `lib/apisix.libsonnet` (add `svc`)

- [ ] **Step 1: Add the service to `generate_manifest`**

Add after `deployment` (with its trailing comma):

```jsonnet
        svc: svcs.serviceFor(self.deployment),
```

- [ ] **Step 2: Run the full render harness (all assertions)**

Run: `RENDER -J lib /tmp/render_apisix.jsonnet`
Expected: the object now also includes `has_svc`-equivalent — add to the harness:

```jsonnet
  svc_kind: m.svc.kind,
  svc_name: m.svc.metadata.name,
```
Expected:
```json
   "svc_kind": "Service",
   "svc_name": "ai-gateway",
```
And all Task 3/4 assertions still true.

- [ ] **Step 3: Render the whole manifest to YAML and eyeball it**

Run:
```bash
RENDER -J lib -e 'local a=import "apisix.libsonnet"; local p=import "pim.libsonnet"; a.generate_manifest(p, {namespace:"wisefood-dev",secrets:{api:{groq_api_key:"groq-api-key",openai_key:"openai-key"}}})' | python3 -c 'import sys,json; m=json.load(sys.stdin); print(sorted(m.keys()))'
```
Expected: `['configmap', 'deployment', 'svc']`

- [ ] **Step 4: Commit**

```bash
git add lib/apisix.libsonnet
git commit -m "Add ai-gateway Service to APISIX gateway lib"
```

---

## Task 6: Add the OpenAI key to example_config.yaml

**Files:**
- Modify: `example_config.yaml` (secrets block)

Context (verified): `wisefoodctl.py` ALREADY maps `config.secrets.api.openai_key` →
secret name `openai-key` (alongside `groq_api_key` → `groq-api-key`). The secret is
created with a `password` key via `generate_secrets`. So **no `wisefoodctl.py` change is
needed** — the lib's `config.secrets.api.openai_key` reference (Task 4) already resolves.
The only gap is that `example_config.yaml` (the user-facing sample) does not list the
`openai-key` secret, so operators don't know to supply it.

The current `example_config.yaml` secrets block ends at `session-secret` and does NOT
yet include `groq-api-key` either (the live config in `wisefoodctl.py` is ahead of the
sample). Add BOTH the groq and openai keys to keep the sample consistent with what the
bootstrap expects.

- [ ] **Step 1: Add the api-key entries**

In `example_config.yaml` under `secrets:`, add after the `session-secret` line:

```yaml
  - session-secret: "##YOUR_SESSION_KEY_HERE##" # Secret key for session management
  - groq-api-key: "##YOUR_GROQ_API_KEY_HERE##" # Groq API key (primary LLM provider via AI gateway)
  - openai-key: "##YOUR_OPENAI_API_KEY_HERE##" # OpenAI API key (AI gateway fallback provider)
```

(If `groq-api-key` is already present in the file when you open it, add only the
`openai-key` line.)

- [ ] **Step 2: Verify the file still parses as YAML**

Run: `python3 -c 'import yaml; yaml.safe_load(open("example_config.yaml"))' && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add example_config.yaml
git commit -m "Add Groq and OpenAI API key secrets to sample config for AI gateway"
```

---

## Out of scope (do NOT do)

- Do **not** add the component to `lib/generate.libsonnet`'s component list (user wires it separately).
- Do **not** add an entry to `lib/ingress.libsonnet` (gateway is internal-only).
- Do **not** make live LLM calls; runtime verification happens after wiring + secret provisioning.

## Self-review notes (already reconciled against spec)

- Spec "Steering model" (priority failover, no model-field routing) → Task 3 `proxy_instances` + `fallback_strategy`.
- Spec ConfigMap (config.yaml + apisix.yaml + #END) → Tasks 2 & 3.
- Spec deployment (mount, $ENV:// keys, port) → Task 4.
- Spec svc → Task 5; pim port → Task 1; new OpenAI secret → Task 6.
- Image pinned to `apache/apisix:3.14.1-debian` (current maintained release).
- `ai-rate-limiting` token cap intentionally deferred to a documented one-line addition (Task 3 note) to avoid premature over-restriction — flagged, not silently dropped.
