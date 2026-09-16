
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

        deployment: deploy.new(name="recipewrangler", containers=[
            container.new("fs", pim.images.RECIPEWRANGLER)
            // Explicit, though :latest already implies it — the db-rw container
            // below says it too, and a pull policy you have to infer from the
            // tag is one more thing to get wrong. Note this still only governs
            // whether a STARTING pod pulls: pushing a new :latest does nothing
            // until the pod is replaced, which is what `tk apply` does here by
            // changing the pod template.
            + container.withImagePullPolicy("Always")
            + container.withEnvMap({
                LOG_FORMAT: pim.observability.LOG_FORMAT,
                ANALYTICS_ENABLED: std.toString(pim.observability.ANALYTICS_ENABLED),
                ANALYTICS_INGEST_URL: pim.observability.ANALYTICS_INGEST_URL,
                // Shared with the gateway. Unset closes the ingest endpoint and
                // leaves this service reporting nothing — off, never open.
                ANALYTICS_INGEST_SECRET: envSource.secretKeyRef.withName(config.secrets.api.analytics_ingest)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
                CHROMA_HOST: "chromadb",
                EMBED_MODEL_NAME: "BAAI/bge-small-en-v1.5",
                EMBED_BATCH_SIZE: "256",
		        EMBED_DEVICE: "cpu",
                CHROMA_PORT: std.toString(pim.ports.CHROMA),
                GROQ_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.groq_api_key)+envSource.secretKeyRef.withKey("password"),
                // Models. Every model the app talks to is named here; nothing is
                // left to an in-image default (same rule as foodchat.libsonnet
                // and foodscholar.libsonnet). RecipeWrangler was the one service
                // that did NOT follow that rule, and it is the reason this block
                // exists: when Groq shut down llama-3.3-70b-versatile and
                // llama-3.1-8b-instant on 2026-08-16, its six in-image defaults
                // went dead with nothing here to override them. The parser was
                // the visible casualty — POST /recipes/profile answered 503
                // "Profiling pipeline request failed." on every call, which read
                // as an outage rather than as a dead model id. Naming the ids
                // here is what makes the next retirement a config edit instead
                // of a rebuild.
                //
                // Extraction and parsing — span-picking against a strict schema
                // rather than judgment. gpt-oss-20b is verified against
                // ParsedRecipe's seven required fields; llama-3.1-8b-instant was
                // rejected for this job long ago because it routinely omitted
                // `directions`, so do not put an 8b-class model back here.
                SEARCH_LLM_SOURCE: "groq",
                SEARCH_MAIN_MODEL: "openai/gpt-oss-20b",
                GUARDRAILS_MODEL: "openai/gpt-oss-20b",
                PARSE_LLM: "openai/gpt-oss-20b",
                WEIGHT_LLM: "openai/gpt-oss-20b",
                // The substitution judge, which decides whether a candidate that
                // lowers a recipe's carbon footprint is actually a sensible swap.
                //
                // ADAPT_LLM_SOURCE is the important line: the app defaults it to
                // `vllm` at localhost:8005, and no vLLM is deployed in this
                // cluster. rerank_with_llm returns None on ANY failure and the
                // caller falls back to deterministic ranking, so that default
                // silently disabled the judge instead of failing — which is what
                // produced the Round 2 finding that sustainability substitutions
                // were nutritionally illogical (milk -> condensed milk). Judgment
                // tier, so 120b, matching the other two services.
                ADAPT_LLM_SOURCE: "groq",
                ADAPT_LLM_MODEL: "openai/gpt-oss-120b",
                NEO4J_URI: "bolt://neo4j:7687",
                NEO4J_AUTH: envSource.secretKeyRef.withName(config.secrets.neo4j.neo4j_auth)+envSource.secretKeyRef.withKey("password"),
	            NUTRITION_DB: "nutrients",
		        NUTRITION_USER: "postgres",
                RECIPE_CACHE_ENABLED: "true",
                REDIS_URL: "redis://redis:6379",
                REDIS_RECIPE_DB: "7",
                NUTRITION_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.postgres)+envSource.secretKeyRef.withKey("password"),          
                NUTRITION_HOST: "db-rw",
                NUTRITION_PROFILES_TABLE: "nutrients-recipe-profiles",
                ELASTIC_URL: "http://elastic:"+std.toString(pim.ports.ELASTIC),
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.RECIPEWRANGLER, "fs"),
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'rw',
        'app.kubernetes.io/component': 'recipewrangler',
        }),

        fs_svc: svcs.serviceFor(self.deployment),

        pvc_db_storage: pvol.pvcWithDynamicStorage(
            "postgres-rw-storage", 
            "12Gi", 
            pim.dynamic_volume_storage_class),

        postgres_deployment: stateful.new(name="db-rw", containers=[
            container.new("postgres-rw", pim.images.RECIPEWRANGLER_DB)
            + container.withImagePullPolicy("Always")
            + container.withEnvMap({
                /* We are using /var/lib/postgresql/data as mountpoint, and initdb does not like it,
                so we just use a subdirectory...
                */
                PGDATA: "/var/lib/postgresql/data/pgdata",
                POSTGRES_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.postgres)+envSource.secretKeyRef.withKey("password"),       
            })
            // Expose port 
            + container.withPorts([
                containerPort.newNamed(pim.ports.DB, "psql")      
            ])
            // liveness check
            + container.livenessProbe.exec.withCommand([
                "pg_isready", "-U", "postgres"
            ])
            + container.livenessProbe.withInitialDelaySeconds(30)
            + container.livenessProbe.withPeriodSeconds(10)
            + container.withVolumeMounts([
                volumeMount.new("postgres-rw-storage-vol", "/var/lib/postgresql/data", false)
            ])
        ],
        podLabels={
            'app.kubernetes.io/name': 'rw-db',
            'app.kubernetes.io/component': 'postgres-rw',
        })
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("postgres-rw-storage-vol", "postgres-rw-storage")
        ]),

        postgres_svc: svcs.headlessService.new("db-rw", "postgres-rw", pim.ports.DB)
    }

}
