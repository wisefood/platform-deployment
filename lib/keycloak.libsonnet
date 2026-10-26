
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

local HOSTNAME(config) = dns.kc_domain_scheme(config);

local KEYCLOAK_CONFIG(pim,config) = {
    local db_url = "jdbc:postgresql://%(host)s:%(port)s/%(db)s" % { 
                                                            host: pim.db.POSTGRES_HOST, 
                                                            port: pim.ports.DB,
                                                            db: pim.db.WISEFOOD_DB
                                                          },
    KC_DB: pim.keycloak.DB_TYPE,
    KC_DB_URL: db_url,
    KC_DB_USERNAME: pim.db.KEYCLOAK_USER,
    KC_DB_SCHEMA: pim.db.KEYCLOAK_SCHEMA,
    KEYCLOAK_ADMIN: pim.keycloak.KEYCLOAK_ADMIN,
    KC_HOSTNAME: HOSTNAME(config),
    KC_PROXY: "edge",
    KC_HOSTNAME_ADMIN: HOSTNAME(config),
    JDBC_PARAMS: pim.keycloak.JDBC_PARAMS,
    KC_HTTP_ENABLED: pim.keycloak.KC_HTTP_ENABLED,    
    KC_HEALTH_ENABLED: pim.keycloak.KC_HEALTH_ENABLED,
    KC_HOSTNAME_BACKCHANNEL_DYNAMIC: pim.keycloak.KC_HOSTNAME_BACKCHANNEL_DYNAMIC,
    // Read by the WiseFood email theme (core-components keycloak/themes/
    // wisefood, theme.properties). A mail cannot load images from Keycloak's
    // theme resources, so the logo and EU emblem are the console's public
    // copies; the logo links to the app.
    WISEFOOD_APP_URL: config.dns.SCHEME+'://'+config.dns.ROOT_DOMAIN+'/app',
    WISEFOOD_EMAIL_LOGO_URL: config.dns.SCHEME+'://'+config.dns.ROOT_DOMAIN+'/app/email/wisefood-logo.png',
    WISEFOOD_EMAIL_EU_URL: config.dns.SCHEME+'://'+config.dns.ROOT_DOMAIN+'/app/email/eu-emblem.png',
};

{
    generate_manifest(pim,config): {

        deployment: deploy.new(name="keycloak", containers=[
            ########################################
            ## KEYCLOAK  ###########################
            ## Listens on: 8080/9000 of the pod ####
            ########################################
            container.new("keycloak", pim.images.KEYCLOAK)
            + container.withEnvMap(KEYCLOAK_CONFIG(pim, config))
            + container.withEnvMap({
                KC_DB_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.keycloak)+envSource.secretKeyRef.withKey("password"),
                KEYCLOAK_ADMIN_PASSWORD: envSource.secretKeyRef.withName(config.secrets.keycloak.sysadmin_pass)+envSource.secretKeyRef.withKey("password"),
            })
            + container.withCommand(['/opt/keycloak/bin/kc.sh','start','--features=token-exchange,admin-fine-grained-authz'])
            + container.withPorts([
                containerPort.newNamed(pim.ports.KEYCLOAK, "kc"),
                containerPort.newNamed(9000, "kchealth")
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'kc',
        'app.kubernetes.io/component': 'keycloak',
        })
        + deploy.spec.template.spec.withInitContainers([
            podinit.wait4_postgresql("wait4-db", pim, config),
        ]),

        kc_svc: svcs.serviceFor(self.deployment),
    }

}