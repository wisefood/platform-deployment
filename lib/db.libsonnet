/*
    Deployment of the WiseFood core database component as statefulset
 */
local k = import "k.libsonnet";
local podinit = import "podinit.libsonnet";
local pvol = import "pvolumes.libsonnet";
local svcs = import "services.libsonnet";

local deploy = k.apps.v1.deployment;
local stateful = k.apps.v1.statefulSet;
local container = k.core.v1.container;
local containerPort = k.core.v1.containerPort;
local servicePort = k.core.v1.servicePort;
local volumeMount = k.core.v1.volumeMount;
local pod = k.core.v1.pod;
local vol = k.core.v1.volume;
local service = k.core.v1.service;
local cm = k.core.v1.configMap;
local envVar = k.core.v1.envVar;
local envSource = k.core.v1.envVarSource;


local DB_CONFIG(pim) = {

    ########################################
    ##  DEFAULT DATABASE & SERVER ##########
    ########################################  
    POSTGRES_USER: pim.db.POSTGRES_USER,
    POSTGRES_DB: pim.db.POSTGRES_DEFAULT_DB, 
    POSTGRES_HOST: pim.db.POSTGRES_HOST,
    POSTGRES_PORT: std.toString(pim.ports.DB),

    ########################################
    ##  KEYCLOAK SCHEMA AND USER ###########
    ########################################  
    KEYCLOAK_DB: pim.db.WISEFOOD_DB, 
    KEYCLOAK_USER: pim.db.KEYCLOAK_USER,
    KEYCLOAK_SCHEMA: pim.db.KEYCLOAK_SCHEMA, 

    ########################################
    ##  WISEFOOD SCHEMA AND USER ###########
    ########################################
    WISEFOOD_DB: pim.db.WISEFOOD_DB,
    WISEFOOD_USER: pim.db.WISEFOOD_USER,
    WISEFOOD_SCHEMA: pim.db.WISEFOOD_SCHEMA,
};


{

    generate_manifest(pim, config): {

        pvc_db_storage: pvol.pvcWithDynamicStorage(
            "postgres-storage", 
            "5Gi", 
            pim.dynamic_volume_storage_class),

        postgres_deployment: stateful.new(name="db", containers=[
            container.new("postgres", pim.images.POSTGRES_IMAGE)
            + container.withImagePullPolicy("Always")
            + container.withEnvMap(DB_CONFIG(pim))
            + container.withEnvMap({
                /* We are using /var/lib/postgresql/data as mountpoint, and initdb does not like it,
                so we just use a subdirectory...
                */
                PGDATA: "/var/lib/postgresql/data/pgdata",
            })
            // Pass secrets to the container by referencing their names
            + container.withEnvMap({   
                POSTGRES_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.postgres)+envSource.secretKeyRef.withKey("password"),          
                KEYCLOAK_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.keycloak)+envSource.secretKeyRef.withKey("password"),
                WISEFOOD_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.system)+envSource.secretKeyRef.withKey("password"),
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
                volumeMount.new("postgres-storage-vol", "/var/lib/postgresql/data", false)
            ])
        ],
        podLabels={
            'app.kubernetes.io/name': 'system-db',
            'app.kubernetes.io/component': 'postgres',
        })
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("postgres-storage-vol", "postgres-storage")
        ]),

        postgres_svc: svcs.headlessService.new("db", "postgres", pim.ports.DB)

    }

}