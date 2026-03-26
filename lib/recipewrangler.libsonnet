
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

        deployment: deploy.new(name="recipewrangler", containers=[
            container.new("fs", pim.images.RECIPEWRANGLER)
            + container.withEnvMap({
                CHROMA_HOST: "chromadb",
                CHROMA_PORT: std.toString(pim.ports.CHROMA),
                GROQ_API_KEY: envSource.secretKeyRef.withName(config.secrets.api.groq_api_key)+envSource.secretKeyRef.withKey("password"),
                NEO4J_URI: "bolt://neo4j:7687",
                NEO4J_AUTH: envSource.secretKeyRef.withName(config.secrets.neo4j.neo4j_auth)+envSource.secretKeyRef.withKey("password"),
                NUTRITION_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.postgres)+envSource.secretKeyRef.withKey("password"),          
                NUTRITION_HOST: "db-rw",
                ELASTIC_URL: "http://elastic:"+std.toString(pim.ports.ELASTIC),
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.RECIPEWRANGLER, "fs"),
            ]),
        ],
        podLabels={
        'app.kubernetes.io/name': 'rw',
        'app.kubernetes.io/component': 'recipewrangler',
        }),

        fs_svc: svcs.serviceFor(self.deployment),

        pvc_db_storage: pvol.pvcWithDynamicStorage(
            "postgres-rw-storage", 
            "12Gi", 
            pim.dynamic_volume_storage_class),

        postgres_deployment: stateful.new(name="db-rw", containers=[
            container.new("postgres-rw", pim.images.RECIPEWRANGLER_DB)
            + container.withImagePullPolicy("Always")
            + container.withEnvMap({
                /* We are using /var/lib/postgresql/data as mountpoint, and initdb does not like it,
                so we just use a subdirectory...
                */
                PGDATA: "/var/lib/postgresql/data/pgdata",
                POSTGRES_PASSWORD: envSource.secretKeyRef.withName(config.secrets.db.postgres)+envSource.secretKeyRef.withKey("password"),       
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
                volumeMount.new("postgres-rw-storage-vol", "/var/lib/postgresql/data", false)
            ])
        ],
        podLabels={
            'app.kubernetes.io/name': 'rw-db',
            'app.kubernetes.io/component': 'postgres-rw',
        })
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("postgres-rw-storage-vol", "postgres-rw-storage")
        ]),

        postgres_svc: svcs.headlessService.new("db-rw", "postgres-rw", pim.ports.DB)
    }

}