// APISIX 3.16 default enabled plugins (from /apisix/admin/plugins/list).
// Must be listed explicitly because the chart only appends customPlugins to
// the plugins list when apisix.plugins is non-empty.
[
    "real-ip", "ai", "client-control", "proxy-control", "request-id", "zipkin",
    "ext-plugin-pre-req", "fault-injection", "mocking", "serverless-pre-function", "cors", "ip-restriction",
    "ua-restriction", "referer-restriction", "csrf", "uri-blocker", "request-validation", "chaitin-waf",
    "multi-auth", "openid-connect", "cas-auth", "authz-casbin", "authz-casdoor", "wolf-rbac",
    "ldap-auth", "hmac-auth", "basic-auth", "jwt-auth", "jwe-decrypt", "key-auth",
    "consumer-restriction", "attach-consumer-label", "forward-auth", "opa", "authz-keycloak", "proxy-cache",
    "body-transformer", "ai-request-rewrite", "ai-prompt-guard", "ai-prompt-template", "ai-prompt-decorator", "ai-rag",
    "ai-aws-content-moderation", "ai-proxy-multi", "ai-proxy", "ai-rate-limiting", "ai-aliyun-content-moderation", "proxy-mirror",
    "proxy-rewrite", "workflow", "api-breaker", "limit-conn", "limit-count", "limit-req",
    "gzip", "traffic-split", "redirect", "response-rewrite", "mcp-bridge", "degraphql",
    "kafka-proxy", "grpc-transcode", "grpc-web", "http-dubbo", "public-api", "prometheus",
    "datadog", "lago", "loki-logger", "elasticsearch-logger", "echo", "loggly",
    "http-logger", "splunk-hec-logging", "skywalking-logger", "google-cloud-logging", "sls-logger", "tcp-logger",
    "kafka-logger", "rocketmq-logger", "syslog", "udp-logger", "file-logger", "clickhouse-logger",
    "tencent-cloud-cls", "inspect", "example-plugin", "aws-lambda", "azure-functions", "openwhisk",
    "openfunction", "serverless-post-function", "ext-plugin-post-req", "ext-plugin-post-resp",
]
