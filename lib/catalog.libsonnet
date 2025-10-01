
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

        deployment: deploy.new(name="data-catalog", containers=[
            container.new("catalog", pim.images.CATALOG)
            + container.withEnvMap({
                PORT: std.toString(pim.ports.CATALOG),
                CONTEXT_PATH: "/dc",
                APP_EXTERNAL_DOMAIN: config.dns.SCHEME+'://'+config.dns.ROOT_DOMAIN,
                ELASTIC_HOST: "http://elastic:"+std.toString(pim.ports.ELASTIC),
                ES_DIM: pim.catalog.ES_DIM,
                MINIO_ENDPOINT: "http://minio:"+std.toString(pim.ports.MINIOAPI),
                MINIO_BUCKET: pim.catalog.MINIO_BUCKET,
                MINIO_ROOT: 'root',
                MINIO_ROOT_PASSWORD: envSource.secretKeyRef.withName(config.secrets.minio.minio_root)+envSource.secretKeyRef.withKey("password"),
                MINIO_EXT_URL_CONSOLE: config.dns.SCHEME+'://'+config.dns.MINIO_SUBDOMAIN+'.'+config.dns.ROOT_DOMAIN+'/console/',
                MINIO_EXT_URL_API: config.dns.SCHEME+'://'+config.dns.MINIO_SUBDOMAIN+'.'+config.dns.ROOT_DOMAIN,
                KEYCLOAK_URL: "http://keycloak:"+std.toString(pim.ports.KEYCLOAK),
                KEYCLOAK_REALM: pim.keycloak.REALM,
                KEYCLOAK_CLIENT_ID: pim.keycloak.KC_WISEFOOD_PRIVATE_CLIENT_ID,
                KEYCLOAK_CLIENT_SECRET: envSource.secretKeyRef.withName(config.secrets.keycloak.wisefood_api)+envSource.secretKeyRef.withKey("secret"),
                CACHE_ENABLED: "true",
                REDIS_HOST: "redis",
                REDIS_PORT: std.toString(pim.ports.REDIS),
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.CATALOG, "dc"),
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'dc',
        'app.kubernetes.io/component': 'data-catalog',
        })
        + deploy.spec.template.spec.withInitContainers([
            podinit.wait4_http("wait4-elastic", "http://elastic:"+std.toString(pim.ports.ELASTIC)+"/_cluster/health"),
            podinit.wait4_http("wait4-keycloak", "http://keycloak:9000/health/ready"),
        ]),

        dc_svc: svcs.serviceFor(self.deployment),
    }

}