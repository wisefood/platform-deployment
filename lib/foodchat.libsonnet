
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
                CHROMA_MODE: "local",
                CHROMA_HOST: "chromadb",
                CHROMA_PORT: std.toString(pim.ports.CHROMA),
                CSV_HUMMUS_PATH: "/app/src/data/data_kg.csv",
                RECIPE_SOURCE: "api",
                RECIPEWRANGLER_API_URL: "http://recipewrangler:8001",
                NEO4J_URI: "bolt://neo4j:7687",
                NEO4J_AUTH: envSource.secretKeyRef.withName(config.secrets.neo4j.neo4j_auth)+envSource.secretKeyRef.withKey("password"),
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.FOODCHAT, "fc"),
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'fc',
        'app.kubernetes.io/component': 'foodchat',
        }),

        fc_svc: svcs.serviceFor(self.deployment),
    }

}