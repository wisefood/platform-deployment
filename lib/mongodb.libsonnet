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

{

    generate_manifest(pim, config): {

        pvc_mongo: pvol.pvcWithDynamicStorage(
            "mongo-storage", 
            "1.5Gi", 
            pim.dynamic_volume_storage_class),

        mongo: stateful.new(name="mongo", containers=[
            container.new("mongo", pim.images.MONGO)
            + container.withImagePullPolicy("Always")
            + container.withArgs(["--bind_ip_all", "--dbpath=/var/lib/mongo/data"])
            + container.withEnvMap({
                MONGO_INITDB_ROOT_USERNAME: "mongo",
                MONGO_INITDB_ROOT_PASSWORD: envSource.secretKeyRef.withName(config.secrets.mongo.mongo_root)+envSource.secretKeyRef.withKey("password"),          
            })
            + container.withPorts([
                containerPort.newNamed(pim.ports.MONGO, "mongo")      
            ])

            // liveness check
            + container.livenessProbe.tcpSocket.withPort("mongo")
            + container.livenessProbe.withInitialDelaySeconds(30)
            + container.livenessProbe.withPeriodSeconds(10)
            + container.livenessProbe.withTimeoutSeconds(5)
            // readiness check
            + container.readinessProbe.tcpSocket.withPort("mongo")
            + container.readinessProbe.withInitialDelaySeconds(10)
            + container.readinessProbe.withPeriodSeconds(20)
            + container.readinessProbe.withTimeoutSeconds(5)
            + container.withVolumeMounts([
                volumeMount.new("mongo-storage-vol", "/var/lib/mongo/data", false),
            ])
        ],
        podLabels={
            'app.kubernetes.io/name': 'system-mongo',
            'app.kubernetes.io/component': 'mongo',
        })
        + stateful.spec.template.spec.securityContext.withRunAsUser(999)
        + stateful.spec.template.spec.securityContext.withFsGroup(999)
        + stateful.spec.template.spec.securityContext.withRunAsGroup(999)
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("mongo-storage-vol", "mongo-storage"),
        ]),

        mongo_svc: svcs.headlessService.new("mongo", "mongo", pim.ports.MONGO)

    }

}