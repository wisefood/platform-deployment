
local k = import "k.libsonnet";
local svcs = import "services.libsonnet";

local deploy = k.apps.v1.deployment;
local container = k.core.v1.container;
local containerPort = k.core.v1.containerPort;
local volumeMount = k.core.v1.volumeMount;
local vol = k.core.v1.volume;
local cmap = k.core.v1.configMap;
local envSource = k.core.v1.envVarSource;

{
    local apisix_image = "apache/apisix:3.14.1-debian",

    // Priority-based failover. ai-proxy-multi does NOT route by the request's
    // model field; each instance forces its own options.model. Higher priority
    // wins; lower priority is the fallback when the primary fails / is rate-limited.
    local providers = [
        {
            name: "groq-primary",
            provider: "openai-compatible",
            endpoint: "https://api.groq.com/openai/v1/chat/completions",
            auth_env: "GROQ_API_KEY",
            model: "llama-3.3-70b-versatile",
            weight: 1,
            priority: 1,
        },
        {
            name: "openai-fallback",
            provider: "openai",
            endpoint: "https://api.openai.com/v1/chat/completions",
            auth_env: "OPENAI_API_KEY",
            model: "gpt-4o-mini",
            weight: 1,
            priority: 0,
        },
    ],

    local prompt_decorator_prepend = [
        { role: "system", content: "You are an assistant for the WiseFood platform. Be concise and factual." },
    ],
    local prompt_guard_deny = [],

    local token_quota = { limit: 100000, time_window: 60 },
    local request_quota = { count: 120, time_window: 60 },

    local proxy_instances = [
        {
            name: p.name,
            provider: p.provider,
            weight: p.weight,
            priority: p.priority,
            auth: { header: { Authorization: "Bearer $ENV://" + p.auth_env } },
            options: { model: p.model },
            override: { endpoint: p.endpoint },
        }
        for p in providers
    ],

    local route_plugins =
        {
            "ai-proxy-multi": {
                fallback_strategy: ["rate_limiting"],
                balancer: { algorithm: "roundrobin" },
                instances: proxy_instances,
                logging: { summaries: true },
            },
            "limit-count": {
                count: request_quota.count,
                time_window: request_quota.time_window,
                key_type: "var",
                key: "remote_addr",
                rejected_code: 429,
            },
        }
        + (if std.length(prompt_decorator_prepend) > 0
           then { "ai-prompt-decorator": { prepend: prompt_decorator_prepend } }
           else {})
        + (if std.length(prompt_guard_deny) > 0
           then { "ai-prompt-guard": { match_failure_response: "Request blocked by prompt guard.", deny_patterns: prompt_guard_deny } }
           else {}),

    // apisix.yaml MUST end with a literal "#END" line or APISIX won't load it.
    local apisix_yaml =
        std.manifestYamlDoc({
            routes: [
                {
                    uri: "/v1/chat/completions",
                    methods: ["POST"],
                    plugins: route_plugins,
                },
            ],
        })
        + "\n#END\n",

    local config_yaml = std.manifestYamlDoc({
        deployment: {
            role: "data_plane",
            role_data_plane: { config_provider: "yaml" },
        },
        apisix: {
            node_listen: 9080,
            enable_admin: false,
        },
    }),

    generate_manifest(pim, config): {

        configmap: cmap.new("ai-gateway-config")
            + cmap.withData({
                "config.yaml": config_yaml,
                "apisix.yaml": apisix_yaml,
            }),
    },
}
