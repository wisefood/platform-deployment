
local k = import "k.libsonnet";
local pvol = import "pvolumes.libsonnet";
local svcs = import "services.libsonnet";

local container = k.core.v1.container;
local stateful = k.apps.v1.statefulSet;
local containerPort = k.core.v1.containerPort;
local volumeMount = k.core.v1.volumeMount;
local vol = k.core.v1.volume;
local cmap = k.core.v1.configMap;
local envSource = k.core.v1.envVarSource;

{
    generate_manifest(pim, config):  {
        pvc_elastic_storage: pvol.pvcWithDynamicStorage(
            "elastic-storage",
            "5Gi",
            pim.dynamic_volume_storage_class,),

        elastic_deployment: stateful.new(name="elastic", containers=[
            container.new("elastic",pim.images.ELASTIC)
           + container.withImagePullPolicy("Always")
           + container.withEnvMap({
                "discovery.type": "single-node",
                ES_JAVA_OPTS: "-Xms1g -Xmx1g",
                "xpack.security.enabled": "false",
           })
           + container.withPorts([
                containerPort.newNamed(pim.ports.ELASTIC, "es"),
           ])
           + container.withVolumeMounts([
                volumeMount.new("elastic-storage-vol","/data",false)
           ])
        ],
        podLabels={
            'app.kubernetes.io/name': 'data-index',
            'app.kubernetes.io/component': 'elastic',
        })
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("elastic-storage-vol","elastic-storage")
        ]),

       elastic_svc: svcs.headlessService.new("elastic", "elastic", pim.ports.ELASTIC)
    }
}