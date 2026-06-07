# Langfuse observability secrets cascade — Design

**Date:** 2026-06-07
**Author:** petroud

## Goal

Wire optional Langfuse observability credentials through the platform-deployment
config stack so they cascade down to the `foodscholar` workload. Langfuse's
integration in foodscholar activates automatically when both the public and
secret keys are present; when absent, the workload runs normally with tracing
dormant.

Three values are involved:

| Env var on foodscholar | Source | Required? |
|------------------------|--------|-----------|
| `LANGFUSE_PUBLIC_KEY`  | k8s secret `langfuse-public-key` (key `password`) | optional |
| `LANGFUSE_SECRET_KEY`  | k8s secret `langfuse-secret-key` (key `password`) | optional |
| `LANGFUSE_BASE_URL`    | `pim.langfuse.LANGFUSE_BASE_URL` (default) | always set |

Default base URL points at the in-cluster Langfuse service:
`http://langfuse-web.langfuse.svc.cluster.local:3000`

## Layers touched

The two API keys follow the exact same path as the existing `groq_api_key` /
`openai_key` secrets. The base URL follows the platform-independent-model path
(a constant baked into `pim`), since it is the same for every deployment.

### 1. Sample config (`wisefoodctl.py` → `generate_sample_yaml`) + `example_config.yaml`

Add two optional secret entries under `secrets:`:

```yaml
  - langfuse-public-key: "##YOUR_LANGFUSE_PUBLIC_KEY_HERE##" # Langfuse public key (optional, observability)
  - langfuse-secret-key: "##YOUR_LANGFUSE_SECRET_KEY_HERE##" # Langfuse secret key (optional, observability)
```

`generate_secrets()` iterates whatever entries exist in the YAML, so leaving
these out simply means the secrets are never created — no code change needed for
the "optional" behavior at the secret-creation layer.

### 2. Secrets map (`wisefoodctl.py` → `generate_env_main`)

Register the logical secret names under `secrets.api`:

```jsonnet
api: {
    smtp_pass: "smtp-pass",
    session_secret: "session-secret",
    groq_api_key: "groq-api-key",
    openai_key: "openai-key",
    langfuse_public_key: "langfuse-public-key",
    langfuse_secret_key: "langfuse-secret-key",
},
```

### 3. Default base URL (`lib/pim.libsonnet`)

Add a `langfuse` block:

```jsonnet
langfuse: {
    LANGFUSE_BASE_URL: "http://langfuse-web.langfuse.svc.cluster.local:3000",
},
```

### 4. foodscholar env injection (`lib/foodscholar.libsonnet`)

Add three entries to the container env map:

```jsonnet
LANGFUSE_PUBLIC_KEY: envSource.secretKeyRef.withName(config.secrets.api.langfuse_public_key)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
LANGFUSE_SECRET_KEY: envSource.secretKeyRef.withName(config.secrets.api.langfuse_secret_key)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
LANGFUSE_BASE_URL: pim.langfuse.LANGFUSE_BASE_URL,
```

## Optional-secret semantics

The key API secrets use `secretKeyRef` **plus `.withOptional(true)`**. Effect:
when the secret does not exist, Kubernetes skips that env var instead of failing
the pod with `CreateContainerConfigError`. The env var is simply unset, leaving
the foodscholar Langfuse integration dormant — matching "activates when both
keys are present." `withOptional` is confirmed available in the vendored
`k8s-libsonnet/1.32` `secretKeySelector`.

## Out of scope

- No change to other workloads (only foodscholar consumes Langfuse for now).
- No deployment of Langfuse itself (already running in the `langfuse` namespace).
- No `pip install` / application-code changes (handled in the foodscholar repo).
