--
-- STATUS: WORK IN PROGRESS — NOT wired to any live route.
-- Classification (model -> provider, per route config) is verified working.
-- The dynamic upstream selection (upstream.set below) fails at request time with
--   balancer.lua: attempt to get length of field '_priority_index' (a nil value)
-- on APISIX 3.16. The ctx.upstream_conf set here is not consumed as a node-bearing
-- object by pick_server in this build. Needs to be resolved in a non-prod env with
-- error_log:debug against a known-good reference plugin before enabling. The live
-- gateway currently uses an ai-proxy-multi route (see scripts/apisix-llm-routes.sh
-- git history) which sends all admitted traffic to Groq.
--
-- llm-router: route an OpenAI-compatible /chat/completions request to a provider
-- chosen from the request body's `model` field, per ordered rules in the route
-- config. Sets the upstream (host/scheme) and injects the provider's bearer token
-- from an environment variable. Strict: a model matching no rule is rejected.
--
-- The model->provider mapping is ENTIRELY route configuration (see schema), so
-- migrating a model between providers (e.g. llama-* from groq to ollama) is a
-- route-config edit, not a code/image change.
--
-- Delivered via extra_lua_path (mounted ConfigMap); registered in the APISIX
-- `plugins` list. See lib/apisix-gw.libsonnet and scripts/apisix-llm-routes.sh.
--
local core     = require("apisix.core")
local upstream = require("apisix.upstream")

local schema = {
    type = "object",
    properties = {
        -- Provider definitions: name -> connection details.
        providers = {
            type = "object",
            additionalProperties = {
                type = "object",
                properties = {
                    host     = { type = "string" },                 -- e.g. api.groq.com
                    port     = { type = "integer", default = 443 },
                    scheme   = { type = "string", enum = {"http","https"}, default = "https" },
                    path     = { type = "string" },                 -- optional upstream path rewrite
                    auth_env = { type = "string" },                 -- env var holding the bearer token ("" = none)
                },
                required = { "host" },
            },
        },
        -- Ordered rules; first whose Lua pattern matches `model` wins.
        rules = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    match    = { type = "string" },   -- Lua pattern tested against model
                    provider = { type = "string" },   -- key into providers
                },
                required = { "match", "provider" },
            },
        },
        -- What to do when no rule matches: "reject" (400) is the only mode.
        default = { type = "string", enum = {"reject"}, default = "reject" },
    },
    required = { "providers", "rules" },
}

local _M = {
    version  = 0.1,
    priority = 1000,   -- run before ai/proxy plugins so the upstream is set early
    name     = "llm-router",
    schema   = schema,
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then return false, err end
    -- every rule.provider must exist in providers
    for _, r in ipairs(conf.rules) do
        if not conf.providers[r.provider] then
            return false, "rule references unknown provider: " .. r.provider
        end
    end
    return true
end

function _M.access(conf, ctx)
    -- Extract the requested model from the JSON body.
    local body, err = core.request.get_body()
    local model = ""
    if body then
        local ok, j = pcall(core.json.decode, body)
        if ok and type(j) == "table" and j.model then model = j.model end
    end

    -- First matching rule wins.
    local chosen
    for _, r in ipairs(conf.rules) do
        if model:find(r.match) then chosen = r.provider; break end
    end
    if not chosen then
        return 400, { error = "no provider configured for model: " .. model }
    end

    local p = conf.providers[chosen]

    -- Label for per-provider Prometheus metrics.
    ctx.var.llm_provider = chosen

    -- Inject the provider's bearer token from its env var (if any).
    if p.auth_env and p.auth_env ~= "" then
        local token = os.getenv(p.auth_env) or ""
        core.request.set_header(ctx, "Authorization", "Bearer " .. token)
    end

    -- Optional upstream path rewrite.
    if p.path and p.path ~= "" then
        ctx.var.upstream_uri = p.path
    end

    -- Build and set the upstream dynamically, mirroring the in-tree
    -- traffic-split plugin (nodes as an array; parent = matched_route; a unique
    -- per-provider key so the balancer builds a distinct object; set_scheme for
    -- https). A map-form nodes table or a non-unique key triggers the balancer's
    -- `_priority_index nil` runtime error.
    local scheme = p.scheme or "https"
    local port = p.port or upstream.scheme_to_port[scheme] or 443
    local up_conf = {
        type      = "roundrobin",
        scheme    = scheme,
        pass_host = "rewrite",
        upstream_host = p.host,
        nodes     = {
            { host = p.host, port = port, weight = 1, priority = 0 },
        },
    }
    local ok, cerr = upstream.check_schema(up_conf)
    if not ok then
        core.log.error("llm-router: bad upstream for ", chosen, ": ", cerr)
        return 500, { error = "llm-router upstream config error" }
    end

    local matched_route = ctx.matched_route
    up_conf.parent = matched_route
    -- The balancer caches the server-picker by (upstream_key, upstream_version).
    -- Both MUST be unique per provider, else a stale/empty picker is reused and
    -- the balancer hits `_priority_index nil`. Key AND version are per-provider.
    local up_key = "llm-router#route_" .. matched_route.value.id .. "_" .. chosen
    local up_ver = tostring(ctx.conf_version) .. "#llm_" .. chosen
    upstream.set(ctx, up_key, up_ver, up_conf)
    if scheme == "https" then
        upstream.set_scheme(ctx, up_conf)
    end
end

return _M
