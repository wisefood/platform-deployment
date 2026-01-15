
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
local initContainer = k.core.v1.container;


{
    generate_manifest(pim,config): {

        chromadb_pvc: pvol.pvcWithDynamicStorage(
            "chromadb-storage", 
            "5Gi", 
            pim.dynamic_volume_storage_class),

        statefulset: stateful.new(name="chromadb", containers=[
            container.new("chromadb", pim.images.CHROMA)
            + container.withPorts([
                containerPort.newNamed(pim.ports.CHROMA, "cdb"),
            ])
            + container.withVolumeMounts([
                volumeMount.new("chromadb-vol", "/chroma", false),
            ])
        ],
        podLabels={
        'app.kubernetes.io/name': 'chromadb',
        'app.kubernetes.io/component': 'chromadb',
        })
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("chromadb-vol", "chromadb-storage")
        ])
        + stateful.spec.template.spec.withInitContainers([
            container.new("init-chroma", pim.images.CHROMA)
            + container.withCommand([
                "sh", "-c",
                "cp -a /chroma-init/. /chroma/"
            ])
            + container.withVolumeMounts([
                volumeMount.new("chromadb-vol", "/chroma", false),
            ])
        ]),

        chromadb_svc: svcs.serviceFor(self.statefulset),
    }

}