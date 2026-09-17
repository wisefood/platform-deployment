
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
                LOG_FORMAT: pim.observability.LOG_FORMAT,
                ANALYTICS_ENABLED: std.toString(pim.observability.ANALYTICS_ENABLED),
                ANALYTICS_INGEST_URL: pim.observability.ANALYTICS_INGEST_URL,
                // Shared with the gateway. Unset closes the ingest endpoint and
                // leaves this service reporting nothing — off, never open.
                ANALYTICS_INGEST_SECRET: envSource.secretKeyRef.withName(config.secrets.api.analytics_ingest)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
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
                // ...which needs an OpenAI key, and this service did not have
                // one. `guideline_extractor.ensure_api_key()` raises without
                // it, so guideline extraction — the pipeline the Source
                // Integrator drives for every dietary guide — could not run at
                // all. The secret already existed; only APISIX was given it.
                //
                // Optional so a deployment with no OpenAI key still starts:
                // the failure then happens at extraction time with a message
                // that names the cause, rather than as a pod that will not come
                // up for a feature nobody may be using.
                // `key`, not `password`. Every other secret in this file uses
                // `password`, which is exactly why this was wrong: the pattern
                // was copied rather than checked, and `openai-key` holds a
                // single field called `key`. Marking it optional would then
                // have hidden the mistake — the variable would simply be
                // absent and extraction would fail at use, with nothing at
                // apply time to say why.
                OPENAI_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.openai_key)+envSource.secretKeyRef.withKey("key")+envSource.secretKeyRef.withOptional(true),
                // Source Integrator. Writes stay OFF by default even though the
                // Phase 2 pipeline works: turning them on is a decision somebody
                // makes when they are there to watch the first integration, not
                // something a deployment inherits from a new image. With it off,
                // the assistant researches, ranks and proposes as before, and an
                // approved proposal simply has nothing to run.
                INTEGRATOR_WRITES_ENABLED: "false",
                // Named here like every other model this app talks to. The
                // agent loop needs user-defined tool calling, which rules out
                // the Compound systems; research is the one place a Compound
                // model belongs, because its web search is the only web search
                // on this platform.
                INTEGRATOR_MODEL: "openai/gpt-oss-120b",
                INTEGRATOR_RESEARCH_MODEL: "groq/compound",
                // What one conversational turn may spend before it stops and
                // says so. An agent with a search tool and no ceiling can
                // spend an afternoon and a month's quota on one question.
                INTEGRATOR_MAX_STEPS: "12",
                INTEGRATOR_MAX_TOKENS: "120000",
                // The ranking rubric, tunable without a deploy — which was the
                // point of making them settings, and is not true unless they
                // are actually here. Licence dominates because a source we may
                // only point at is worth less than one we may read. Normalised
                // at use, so these are ratios rather than percentages that have
                // to add up.
                INTEGRATOR_WEIGHT_LICENCE: "0.40",
                INTEGRATOR_WEIGHT_COVERAGE_GAP: "0.25",
                INTEGRATOR_WEIGHT_AUTHORITY: "0.20",
                INTEGRATOR_WEIGHT_TRACTABILITY: "0.10",
                INTEGRATOR_WEIGHT_COMPLETENESS: "0.05",
                // How an integration run watches its extraction. The timeout is
                // not a kill — the extraction worker carries on regardless — it
                // is how long one run waits before handing the wait back to a
                // person, who can retry to pick it up.
                INTEGRATOR_POLL_INTERVAL: "20",
                INTEGRATOR_EXTRACTION_TIMEOUT: "3600",
                // Flood control. These routes are already admin-and-expert
                // only, so this is not about strangers: it is about a client
                // stuck in a loop, or one person's credentials being used to
                // spend the platform's Groq budget. Counted from the database
                // rather than a cache, so an outage cannot silently lift them.
                INTEGRATOR_MAX_TURNS_PER_HOUR: "60",
                // Each run holds a thread for as long as its extraction takes,
                // so the total is a ceiling on threads as much as on spend.
                INTEGRATOR_MAX_RUNS_PER_USER: "3",
                INTEGRATOR_MAX_RUNS_TOTAL: "10",
                // Unpaywall asks callers to identify themselves. Ours, never a
                // user's address.
                INTEGRATOR_CONTACT_EMAIL: "info@wisefood-project.eu",
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