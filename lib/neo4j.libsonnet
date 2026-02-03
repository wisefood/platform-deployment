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
local service = k.core.v1.service;
local secret = k.core.v1.secret;
local podinit = import "podinit.libsonnet";
local envSource = k.core.v1.envVarSource;
{
    generate_manifest(pim,config): {

        neo4j_pvc: pvol.pvcWithDynamicStorage(
            "neo4j-storage", 
            "5Gi", 
            pim.dynamic_volume_storage_class),

        statefulset: stateful.new(name="neo4j", containers=[
            container.new("neo4j", pim.images.NEO4J)
            + container.withEnvMap({
                NEO4J_AUTH: envSource.secretKeyRef.withName(config.secrets.neo4j.neo4j_auth)+envSource.secretKeyRef.withKey("password"),
                NEO4J_PLUGINS: '["apoc"]',
                NEO4J_server_config_strict__validation_enabled: "false",
                NEO4J_ACCEPT_LICENSE_AGREEMENT: "yes",
                NEO4J_dbms_default__database: "neo4j",
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.NEO4J, "neo4j"),
                containerPort.newNamed(pim.ports.NEO4J_BOLT, "bolt"),
            ])
            + container.withVolumeMounts([
                volumeMount.new("neo4j-vol", "/data", false),
            ])
        ],
        podLabels={
        'app.kubernetes.io/name': 'neo4j',
        'app.kubernetes.io/component': 'neo4j',
        })
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("neo4j-vol", "neo4j-storage")
        ])
        + stateful.spec.template.spec.withInitContainers([
            container.new("neo4j-import", pim.images.NEO4J)
            + container.withCommand([
                "bash",
                "-c",
                'if [ ! -d "/data/databases/neo4j" ]; then neo4j-admin database load --from-path=/import neo4j --overwrite-destination=true; fi'
                ])
            + container.withVolumeMounts([
                volumeMount.new("neo4j-vol", "/data", false),
            ])
        ]),


        neo4j_svc: svcs.serviceFor(self.statefulset),
    }

}