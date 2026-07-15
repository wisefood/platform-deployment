
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
            pim.dynamic_volume_storage_class,
        ),

        /*
            Elastic Data Catalog + RecipeWrangler Instance
        */
        elastic_deployment: stateful.new(name="elastic", containers=[
            container.new("elastic",pim.images.ELASTIC)
           + container.withImagePullPolicy("Always")
           + container.withEnvMap({
                "discovery.type": "single-node",
                // 1g heap caused multi-second GC stalls on the corpus-scale
                // recipes_v2 index (client read timeouts at 3s). ES guidance:
                // heap <= 50% of container memory, hence the 4Gi limit below.
                ES_JAVA_OPTS: "-Xms2g -Xmx2g",
                "xpack.security.enabled": "false",
           })
           + container.resources.withRequests({ cpu: "500m", memory: "3Gi" })
           + container.resources.withLimits({ memory: "4Gi" })
           + container.withPorts([
                containerPort.newNamed(pim.ports.ELASTIC, "es"),
           ])
           + container.withVolumeMounts([
                volumeMount.new("elastic-storage-vol","/usr/share/elasticsearch/data",false)
           ])
           + container.securityContext.withRunAsUser(1000)
           + container.securityContext.withRunAsGroup(1000)
        ],
        podLabels={
            'app.kubernetes.io/name': 'data-index',
            'app.kubernetes.io/component': 'elastic',
        })
        + stateful.spec.template.spec.withVolumes([
            vol.fromPersistentVolumeClaim("elastic-storage-vol","elastic-storage")
        ])
        + stateful.spec.template.spec.securityContext.withFsGroup(1000)
        + stateful.spec.template.spec.securityContext.withRunAsUser(1000)
        + stateful.spec.template.spec.securityContext.withRunAsNonRoot(true),

        elastic_svc: svcs.headlessService.new("elastic", "elastic", pim.ports.ELASTIC),
    }
}