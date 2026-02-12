
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
                CACHE_ENABLED: "false",
                KEYCLOAK_CLIENT_ID: pim.keycloak.KC_FOODSCHOLAR_CLIENT_ID,
                KEYCLOAK_CLIENT_SECRET: envSource.secretKeyRef.withName(config.secrets.keycloak.foodscholar)+envSource.secretKeyRef.withKey("secret"),
                ENABLE_BACKGROUND_WORKER: "true",
                WORKER_BATCH_SIZE: "50",
                WORKER_POLL_INTERVAL: "300",
                REDIS_HOST: "redis",
                REDIS_PORT: std.toString(pim.ports.REDIS),
                POSTGRES_HOST: pim.db.POSTGRES_HOST,
                POSTGRES_PORT: std.toString(pim.ports.DB),
                POSTGRES_USER: pim.db.WISEFOOD_USER,
                POSTGRES_DB: pim.db.WISEFOOD_DB,
                POSTGRES_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.system)+envSource.secretKeyRef.withKey("password"),
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