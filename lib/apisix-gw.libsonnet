// Apache APISIX API gateway, vendored as a Helm chart and rendered through
// Tanka (tanka-util helm.template). This REPLACES the prior ad-hoc `helm install
// apisix` so the gateway is reproducible from Git like every other component.
//
// Distinct from lib/apisix.libsonnet (the unused standalone-YAML `ai-gateway`
// experiment, which is not wired into any environment). This one is the
// etcd-backed traditional deployment with the Admin API + dashboard.
//
// Chart: charts/apisix (apisix/apisix 2.14.1), vendored via chartfile.yaml.
//
// Values mirror the validated apisix-values.yaml:
//  - prometheus plugin + :9091 exporter + ServiceMonitor (release label matches
//    the kube-prometheus-stack serviceMonitorSelector)
//  - LLM provider keys injected as env vars so routes use $ENV://GROQ_API_KEY /
//    $ENV://OPENAI_API_KEY (APISIX does not support k8s secrets as a manager).
//
// Routes (the multi-provider per-model classifier) are NOT defined here: the
// traditional/etcd deployment takes route config via the Admin API, so routing
// is applied as code by scripts/apisix-llm-routes.sh against the live Admin API.
//
// Custom plugin: lib/apisix-plugins/llm-router.lua is shipped as a ConfigMap and
// registered via the chart's apisix.customPlugins. It selects an LLM provider
// from the request's `model` field per route config and sets the upstream +
// auth — the only way to do true model->provider routing on this APISIX version.
local tanka = import "github.com/grafana/jsonnet-libs/tanka-util/main.libsonnet";
local k = import "k.libsonnet";
local cmap = k.core.v1.configMap;
local defaultPlugins = import "apisix-default-plugins.libsonnet";
local helm = tanka.helm.new(std.thisFile);

// APISIX loads custom plugins from <luaPath base>/apisix/plugins/<name>.lua.
local plugin_lua_path = "/wisefood-plugins/?.lua";
local plugin_cm_name = "apisix-llm-router-plugin";

{
    generate_manifest(pim, config): {
        // ConfigMap holding the custom plugin Lua. The chart's customPlugins
        // mounts it at apisix/plugins/llm-router.lua under the luaPath base.
        plugin_cm:
            cmap.new(plugin_cm_name)
            + cmap.metadata.withNamespace("apisix")
            + cmap.withData({
                "llm-router.lua": importstr "apisix-plugins/llm-router.lua",
            }),

        apisix:
            local rendered = helm.template("apisix", "../charts/apisix", {
                namespace: "apisix",
                values: {
                    apisix: {
                        prometheus: {
                            enabled: true,
                            path: "/apisix/prometheus/metrics",
                            metricPrefix: "apisix_",
                            containerPort: 9091,
                        },
                        // $ENV:// resolution requires the env var names to be
                        // DECLARED here (nginx.envs), not just set on the container
                        // (extraEnvVars). Without this, $ENV://GROQ_API_KEY resolves
                        // to empty and the gateway sends an empty bearer token.
                        nginx: {
                            envs: ["GROQ_API_KEY", "OPENAI_API_KEY"],
                        },
                        // The chart only registers customPlugins into the plugins
                        // list when apisix.plugins is non-empty, so we set the full
                        // default list explicitly; the chart appends llm-router.
                        plugins: defaultPlugins,
                        // Register and mount the custom llm-router plugin.
                        customPlugins: {
                            enabled: true,
                            luaPath: plugin_lua_path,
                            plugins: [
                                {
                                    name: "llm-router",
                                    attrs: {},
                                    configMap: {
                                        name: plugin_cm_name,
                                        // The chart uses `path` as the volumeMount
                                        // mountPath and `key` as the subPath, so
                                        // `path` must be the full FILE path (not the
                                        // directory) for APISIX to find it under
                                        // <luaPath base>/apisix/plugins/<name>.lua.
                                        mounts: [
                                            { key: "llm-router.lua", path: "/wisefood-plugins/apisix/plugins/llm-router.lua" },
                                        ],
                                    },
                                },
                            ],
                        },
                    },
                    metrics: {
                        serviceMonitor: {
                            enabled: true,
                            interval: "15s",
                            labels: { release: "kube-prometheus-stack" },
                        },
                    },
                    extraEnvVars: [
                        {
                            name: "GROQ_API_KEY",
                            valueFrom: { secretKeyRef: {
                                name: config.secrets.api.groq_api_key,
                                key: "password",
                            } },
                        },
                        {
                            name: "OPENAI_API_KEY",
                            valueFrom: { secretKeyRef: {
                                name: config.secrets.api.openai_key,
                                key: "key",
                            } },
                        },
                    ],
                },
            });
            // helm.template returns a map keyed by "kind/name"; Tanka wants the
            // values as a flat list. We drop Helm lifecycle hooks (e.g. the
            // etcd pre-upgrade Job): they are one-shot, have immutable pod
            // templates, and re-applying them fails. tk apply manages the
            // steady-state resources only.
            local isHelmHook(o) =
                std.isObject(o)
                && std.objectHas(o, "metadata")
                && std.isObject(o.metadata)
                && std.objectHas(o.metadata, "annotations")
                && std.isObject(o.metadata.annotations)
                && std.objectHas(o.metadata.annotations, "helm.sh/hook");
            [
                rendered[k]
                for k in std.objectFields(rendered)
                if std.isObject(rendered[k]) && !isHelmHook(rendered[k])
            ],
    },
}
