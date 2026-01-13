
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

        deployment: deploy.new(name="wisefood-ui", containers=[
            container.new("ui", pim.images.UI)
            + container.withPorts([
                containerPort.newNamed(pim.ports.UI, "ui"),
            ])
            + container.withEnvMap({
                VITE_KEYCLOAK_URL: dns.kc_domain_scheme(config),
                VITE_KEYCLOAK_REALM: pim.keycloak.REALM,
                VITE_KEYCLOAK_CLIENT_ID: "wisefood-ui",
                VITE_WISEFOOD_API_URL: dns.api_url_scheme(config),
                SESSION_SECRET: envSource.secretKeyRef.withName(config.secrets.api.session_secret)+envSource.secretKeyRef.withKey("password"),
            })
        ],
        podLabels={
        'app.kubernetes.io/name': 'ui',
        'app.kubernetes.io/component': 'wisefood-ui',
        }),

        ui_svc: svcs.serviceFor(self.deployment),
    }

}