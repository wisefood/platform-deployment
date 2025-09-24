local k = import "k.libsonnet";
local podinit = import "podinit.libsonnet";
local rbac = import "rbac.libsonnet";
local images = import "images.libsonnet";


local deploy = k.apps.v1.deployment;
local job = k.batch.v1.job;
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
local envSource = k.core.v1.envVarSource;
local volumeMount = k.core.v1.volumeMount;

{
    generate_manifest(pim,config): {

        authinitjob: job.new("auth-init-job")
            + job.metadata.withLabels({
                'app.kubernetes.io/name': 'auth-init',
                'app.kubernetes.io/component': 'authinit',
            })
            + job.spec.template.spec.withContainers(containers=[
                container.new("auth-init-container", pim.images.KEYCLOAK_INIT)
                + container.withImagePullPolicy("Always")
                + container.withEnvMap({
                    KEYCLOAK_ADMIN : pim.keycloak.KEYCLOAK_ADMIN,
                    KEYCLOAK_ADMIN_PASSWORD : envSource.secretKeyRef.withName(config.secrets.keycloak.sysadmin_pass)+envSource.secretKeyRef.withKey("password"),
                    KEYCLOAK_ADMIN_EMAIL: config.admin.email,
                    KEYCLOAK_REALM: pim.keycloak.REALM,
                    KEYCLOAK_PORT: std.toString(pim.ports.KEYCLOAK),
                    KEYCLOAK_DOMAIN: config.dns.SCHEME + "://"+config.dns.KEYCLOAK_SUBDOMAIN+"."+config.dns.ROOT_DOMAIN,
                    KUBE_NAMESPACE: pim.namespace,
                    KC_MINIO_CLIENT_ID: pim.keycloak.KC_MINIO_CLIENT_ID,
                    KC_PUBLIC_CLIENT_ID: pim.keycloak.KC_WISEFOOD_PUBLIC_CLIENT_ID,
                    KC_PRIVATE_CLIENT_ID: pim.keycloak.KC_WISEFOOD_PRIVATE_CLIENT_ID,

                    MINIO_REDIRECT: config.dns.SCHEME+"://"+config.dns.MINIO_SUBDOMAIN+"."+config.dns.ROOT_DOMAIN+"/console/oauth_callback",
                    PUBLIC_REDIRECT: config.dns.SCHEME+"://"+config.dns.ROOT_DOMAIN+"/*",

                    MINIO_ORIGIN: config.dns.SCHEME+"://"+config.dns.MINIO_SUBDOMAIN+"."+config.dns.ROOT_DOMAIN,
                    PUBLIC_ORIGIN: config.dns.SCHEME+"://"+config.dns.ROOT_DOMAIN,
                    
                    MINIO_API_DOMAIN: config.dns.SCHEME+"://"+config.dns.MINIO_SUBDOMAIN+"."+config.dns.ROOT_DOMAIN,
                    MINIO_ROOT: 'root',
                    MINIO_ROOT_PASSWORD: envSource.secretKeyRef.withName(config.secrets.minio.minio_root)+envSource.secretKeyRef.withKey("password"),
                    MC_INSECURE: std.toString(config.dns.SCHEME == "http"),
                })
            ])
            + job.spec.template.spec.withInitContainers([
                podinit.wait4_postgresql("wait4-db", pim, config),
                podinit.wait4_http("wait4-keycloak", "http://keycloak:9000/health/ready"),
            ])
            + job.spec.template.spec.withServiceAccountName("sysinit")
            + job.spec.template.spec.withRestartPolicy("Never"),


        initrbac: rbac.namespacedRBAC("sysinit", [
            rbac.resourceRule(
                ["create","get","list","update","delete"],
                [""],
                ["secrets","configmaps"])
        ]),
    }
}