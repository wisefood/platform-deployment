
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
local dns = import "dns.libsonnet";

{
    generate_manifest(pim,config): {

        deployment: deploy.new(name="foodchat", containers=[
            container.new("fc", pim.images.FOODCHAT)
            + container.withEnvMap({
                PORT: std.toString(pim.ports.FOODCHAT),
                GROQ_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.groq_api_key)+envSource.secretKeyRef.withKey("password"),
                WISEFOOD_CLIENT_ID: pim.keycloak.KC_FOODCHAT_CLIENT_ID,
                WISEFOOD_CLIENT_SECRET: envSource.secretKeyRef.withName(config.secrets.keycloak.foodchat)+envSource.secretKeyRef.withKey("secret"),
                WISEFOOD_API_URL: dns.core_api_url_scheme(config),
                RECIPEWRANGLER_API_URL: "http://recipewrangler:8001",
                // FoodScholar bridge (M1): nutrition-science answers in chat
                FOODSCHOLAR_API_URL: "http://foodscholar:8001",
                // Session store: dedicated 'foodchat' database on the platform Postgres.
                // The app only reads DATABASE_URL, but the DB password lives in a k8s
                // Secret and cannot be inlined here. We therefore rely on Kubernetes
                // dependent env var expansion: withEnvMap renders env entries in
                // alphabetical key order, so DATABASE_PASSWORD precedes DATABASE_URL
                // in the env list and the kubelet substitutes $(DATABASE_PASSWORD)
                // at container start. Do not rename these vars without preserving
                // that ordering.
                DATABASE_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.system)+envSource.secretKeyRef.withKey("password"),
                DATABASE_URL: "postgresql://"+pim.db.WISEFOOD_USER+":$(DATABASE_PASSWORD)@"+pim.db.POSTGRES_HOST+":"+std.toString(pim.ports.DB)+"/"+pim.db.FOODCHAT_DB,
                // Langfuse tracing (same wiring as foodscholar.libsonnet)
                LANGFUSE_PUBLIC_KEY: envSource.secretKeyRef.withName(config.secrets.api.langfuse_public_key)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
                LANGFUSE_SECRET_KEY: envSource.secretKeyRef.withName(config.secrets.api.langfuse_secret_key)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
                LANGFUSE_BASE_URL: pim.langfuse.LANGFUSE_BASE_URL,
                // Models. Every model the app talks to is named here; nothing is
                // hardcoded in the image (same rule as foodscholar.libsonnet).
                // Groq shut down llama-3.3-70b-versatile and llama-3.1-8b-instant
                // on 2026-08-16 and BOTH were FoodChat's in-image defaults, so
                // this block is what actually moves it off them.
                //
                // Resolution in the app is narrowest-wins:
                //   FOODCHAT_FAST_MODEL  -> the five structured-output extractors
                //   FOODCHAT_LLM_MODEL   -> every other agent (unset = inherit below)
                //   GROQ_DEFAULT_MODEL   -> fleet default
                // Set the narrowest level you actually mean; a level left unset
                // inherits the next one down. Do not set FOODCHAT_LLM_MODEL to the
                // same value as GROQ_DEFAULT_MODEL — that only hides which one wins.
                //
                // The reasoning tier: batch plan grader, intent orchestrator,
                // diversity/guideline judges, query reconciler, prose writers.
                // Same id foodscholar runs for the equivalent job, deliberately:
                // one reasoning family across the platform is one set of quirks
                // to handle, and the gpt-oss pair is the one already exercised
                // here in production. qwen/qwen3.6-27b is the cheaper fallback if
                // cost becomes the binding constraint — uncomment below.
                GROQ_DEFAULT_MODEL: "openai/gpt-oss-120b",
                // FOODCHAT_LLM_MODEL: "qwen/qwen3.6-27b",
                // Dietary tags, plan spec, seed dishes, preferences and edit
                // commands: span-picking rather than judgment, and several of them
                // run per planning turn.
                FOODCHAT_FAST_MODEL: "openai/gpt-oss-20b",
                GROQ_DEFAULT_TEMPERATURE: "0.0",
                // Reasoning families charge hidden reasoning against the same
                // completion budget as the payload; this clears the 2048 floor
                // foodscholar measured for gpt-oss/qwen3 with room for the batch
                // grader, whose response scales with FOODCHAT_MAX_PLANS_TO_SCORE.
                GROQ_DEFAULT_MAX_TOKENS: "4096",
                // CRITICAL|ERROR|WARNING|INFO|DEBUG; anything else falls back to
                // The data catalog, for dietary guidelines.
                //
                // Unset, FoodChat grades every plan against three hardcoded
                // rules — real guidance, and identical for a member in Ireland,
                // Slovenia, Hungary or Greece. Set, it reads the member's own:
                // the catalog holds ~2,700 rules faceted by region, life stage
                // and health condition.
                //
                // The gateway does NOT proxy the catalog's guideline routes, so
                // this is a direct in-cluster call authenticated with the same
                // Keycloak client pair FoodChat already uses for profiles.
                // Unreachable or slow degrades to the hardcoded three; it never
                // fails a plan.
                DATA_API_URL: "http://data-catalog:"+std.toString(pim.ports.CATALOG),
                // The signed member assertion shared with wisefood-api.
                //
                // FoodChat takes `member_id` as DATA and believes it; only the
                // gateway can answer "does this Keycloak user own this member",
                // because the household tables live there. So the gateway signs
                // that answer and FoodChat verifies the signature — without
                // which anything that can reach this pod's port can act as any
                // member alive.
                //
                // Setting this IS the enable step: there is no separate flag,
                // because a security control with its own feature flag ships
                // disabled and stays that way. Unset on either side, both
                // services behave exactly as they did before, so they can be
                // rolled out in either order. It MUST be the same value in
                // lib/api.libsonnet — a mismatch rejects every request.
                FOODCHAT_ASSERTION_SECRET: envSource.secretKeyRef.withName(config.secrets.api.foodchat_assertion)+envSource.secretKeyRef.withKey("password")+envSource.secretKeyRef.withOptional(true),
                // INFO rather than failing the boot. The image defaults to INFO,
                // so this exists to raise verbosity without a rebuild.
                LOG_LEVEL: "INFO",
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.FOODCHAT, "fc"),
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'fc',
        'app.kubernetes.io/component': 'foodchat',
        })
        + deploy.spec.template.spec.withInitContainers([
            podinit.wait4_postgresql("wait4-db", pim, config),
        ]),

        fc_svc: svcs.serviceFor(self.deployment),
    }

}