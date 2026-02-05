
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
            container.new("fc", pim.images.foodchat)
            + container.withEnvMap({
                PORT: std.toString(pim.ports.foodchat),
                GROQ_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.groq_api_key)+envSource.secretKeyRef.withKey("password"),
                WISEFOOD_CLIENT_ID: pim.keycloak.KC_FOODCHAT_CLIENT_ID,
                WISEFOOD_CLIENT_SECRET: envSource.secretKeyRef.withName(config.secrets.keycloak.foodchat)+envSource.secretKeyRef.withKey("secret"),
                WISEFOOD_API_URL: dns.core_api_url_scheme(config),
                CHROMA_MODE: "remote",
                CHROMA_HOST: "chromadb",
                CHROMA_PORT: pim.ports.CHROMA

            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.foodchat, "fc"),
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'fc',
        'app.kubernetes.io/component': 'foodchat',
        }),

        fc_svc: svcs.serviceFor(self.deployment),
    }

}