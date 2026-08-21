
local k = import "k.libsonnet";
local pvol = import "pvolumes.libsonnet";
local svcs = import "services.libsonnet";
local PORT = import "stdports.libsonnet";

local deploy = k.apps.v1.deployment;
local container = k.core.v1.container;
local stateful = k.apps.v1.statefulSet;
local containerPort = k.core.v1.containerPort;
local pod = k.core.v1.pod;
local port = k.core.v1.containerPort;
local volumeMount = k.core.v1.volumeMount;
local vol = k.core.v1.volume;
local cmap = k.core.v1.configMap;
local service = k.core.v1.service;
local secret = k.core.v1.secret;
local podinit = import "podinit.libsonnet";
local envSource = k.core.v1.envVarSource;

{
    generate_manifest(pim,config): {

        deployment: deploy.new(name="foodscholar", containers=[
            container.new("fs", pim.images.FOODSCHOLAR)
            + container.withEnvMap({
                PORT: std.toString(pim.ports.FOODSCHOLAR),
                GROQ_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.groq_api_key)+envSource.secretKeyRef.withKey("password"),
                LANGFUSE_PUBLIC_KEY: envSource.secretKeyRef.withName(config.secrets.api.langfuse_public_key)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
                LANGFUSE_SECRET_KEY: envSource.secretKeyRef.withName(config.secrets.api.langfuse_secret_key)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
                LANGFUSE_BASE_URL: pim.langfuse.LANGFUSE_BASE_URL,
                CACHE_ENABLED: "false",
                KEYCLOAK_CLIENT_ID: pim.keycloak.KC_FOODSCHOLAR_CLIENT_ID,
                KEYCLOAK_CLIENT_SECRET: envSource.secretKeyRef.withName(config.secrets.keycloak.foodscholar)+envSource.secretKeyRef.withKey("secret"),
                ENABLE_BACKGROUND_WORKER: "false",
                WISEFOOD_API_URL: "http://wisefood-api:8000",
                WORKER_BATCH_SIZE: "50",
                WORKER_POLL_INTERVAL: "300",
                REDIS_HOST: "redis",
                REDIS_PORT: std.toString(pim.ports.REDIS),
                POSTGRES_HOST: pim.db.POSTGRES_HOST,
                POSTGRES_PORT: std.toString(pim.ports.DB),
                POSTGRES_USER: pim.db.WISEFOOD_USER,
                POSTGRES_DB: pim.db.WISEFOOD_DB,
                POSTGRES_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.system)+envSource.secretKeyRef.withKey("password"),
                   // Models. Every model the app talks to is named here; nothing
                // is hardcoded in the image. Groq shut down both Llama ids on
                // 2026-08-16, so all Groq-backed roles run reasoning models
                // and rely on backend/model_profiles.py to hide reasoning and
                // floor the token budget.
                QA_DEFAULT_MODEL: "openai/gpt-oss-120b",
                // Also the API contract: advertised by GET /qa/models and
                // enforced on advanced-mode requests. QA_DEFAULT_MODEL must
                // appear in it, or the app refuses to start.
                QA_AVAILABLE_MODELS: std.join(",", [
                    "openai/gpt-oss-120b",
                    "openai/gpt-oss-20b",
                ]),
                QA_FAST_MODEL: "openai/gpt-oss-20b",
                QA_UTILITY_MODEL: "openai/gpt-oss-20b",
                SESSION_TITLE_MODEL: "openai/gpt-oss-20b",
                SESSION_CHAT_MODEL: "openai/gpt-oss-120b",
                SYNTHESIS_MODEL: "openai/gpt-oss-120b",
                MEMORY_EXTRACTOR_MODEL: "openai/gpt-oss-20b",
                ENRICHMENT_KEYWORD_MODEL: "openai/gpt-oss-20b",
                ENRICHMENT_ANNOTATION_MODEL: "openai/gpt-oss-20b",
                GUIDELINE_ENRICHMENT_MODEL: "openai/gpt-oss-20b",
                // OpenAI, not Groq: vision over rendered PDF pages.
                GUIDELINE_EXTRACTION_MODEL: "gpt-5.4",
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.FOODSCHOLAR, "fs"),
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'fs',
        'app.kubernetes.io/component': 'foodscholar',
        })
        + deploy.spec.template.spec.withInitContainers([
            podinit.wait4_postgresql("wait4-db", pim, config),
            podinit.wait4_http("wait4-elastic", "http://elastic:"+std.toString(pim.ports.ELASTIC)+"/_cluster/health"),
        ]),

        fs_svc: svcs.serviceFor(self.deployment),
    }

}