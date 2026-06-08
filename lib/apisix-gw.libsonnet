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
local tanka = import "github.com/grafana/jsonnet-libs/tanka-util/main.libsonnet";
local helm = tanka.helm.new(std.thisFile);

{
    generate_manifest(pim, config): {
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
