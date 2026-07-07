
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