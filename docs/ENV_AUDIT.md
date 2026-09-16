# Environment audit — what each service reads against what it is given

_Run 2026-09-16 against `environments/wf-prod`._

Every `os.getenv` / `os.environ` read in each service's `src/`, diffed against
the env rendered by `tk eval`. The point is not the count — most unset
variables are tuning knobs whose code defaults are correct and deliberate —
but the handful where the default is wrong, or where a documented promise was
not actually kept.

| service | reads | provided | genuinely missing |
|---|---|---|---|
| foodscholar | 100 | 51 → 52 | **1 (fixed)** |
| wisefood-api | 62 | 49 | 0 |
| recipewrangler | 83 | 28 | 0 |
| foodchat | 50 | 23 | 0 |

**There is no dead config.** Everything the deployment sets is read. The
variables that appear unread to a naive scan — `ANALYTICS_ENABLED`,
`SMTP_PORT`, `INTEGRATOR_WEIGHT_*` — are reached through helpers (`_env_port`)
or built dynamically (`f"INTEGRATOR_WEIGHT_{component}"`), so the literal never
appears in the source.

## Fixed by this audit

**`OPENAI_API_KEY` was missing from foodscholar, and guideline extraction
cannot run without it.** `GUIDELINE_EXTRACTION_MODEL` is `gpt-5.4` — OpenAI,
not Groq, because the extractor does vision over rendered PDF pages — and
`guideline_extractor.ensure_api_key()` raises outright when the key is unset.
The client is constructed as a bare `OpenAI()` with no `base_url`, so it is a
direct call rather than one routed through APISIX.

This is the pipeline the Source Integrator drives for **every dietary guide**,
so Phase 2 would have failed at the extraction step in production while
passing every test. The secret already existed; only APISIX had been given it.
Now wired, and marked optional so a deployment without an OpenAI key still
starts and fails at extraction time with a message naming the cause, rather
than as a pod that will not come up for a feature nobody may be using.

**Nine `INTEGRATOR_*` variables were absent**, so they silently took image
defaults. Two of those contradicted commitments this repository had already
made: `lib/foodscholar.libsonnet` states that every model the app talks to is
named there and nothing is hardcoded in the image, while `INTEGRATOR_MODEL`
and `INTEGRATOR_RESEARCH_MODEL` were hardcoded in the image; and the plan made
the rubric weights settings specifically so ranking could be tuned without a
deploy, which required a deploy because they were not there. All 16 now render.

**`recipe_source_import` was not schema-qualified.** Every other query in
RecipeWrangler's Postgres layer qualifies its table with `NUTRITION_SCHEMA`;
the new source-import run table used a bare name, which resolves through
`search_path` to `public`. That agrees with the default and would have quietly
disagreed with any deployment that set the schema to something else.

## Deliberately unset, and correct

Most of the gap is this, and it is not a problem:

* **Tuning knobs** — `QA_*` retrieval weights, `NUTRITION_*` pool sizes,
  `ELASTIC_*` timeouts, `USDA_LINKS_*` thresholds, `GUIDELINE_JOB_*` queue
  keys. Their code defaults are the intended values; setting them in the
  deployment would mean two places to change one number.
* **Workers** — `ENABLE_GUIDELINE_EXTRACTION_WORKER`,
  `ENABLE_ENRICHMENT_JOB_WORKER` and `ENABLE_GUIDELINE_ENRICHMENT_WORKER` all
  default to `true`, so extraction and enrichment run. Checked, because a
  queue nothing drains looks identical to a slow one.
* **Derived URLs** — `DATA_API_URL` defaults to `http://data-catalog:8000`,
  and `WISEFOOD_PLATFORM_API_URL` falls back to `WISEFOOD_API_URL`, which is
  set. Both resolve correctly in-cluster.
* **Credentials read under another name** — `WISEFOOD_CLIENT_ID` /
  `WISEFOOD_CLIENT_SECRET` appear unset, but the platform client pools
  authenticate with `KEYCLOAK_CLIENT_ID` / `KEYCLOAK_CLIENT_SECRET`, which are
  provided. Likewise RecipeWrangler's `POSTGRES_*` and `NEO4J_USER` /
  `NEO4J_PASSWORD`: it is given `NUTRITION_*` and `NEO4J_AUTH`, and the config
  layer prefers those.

## How to re-run this

```
python scan_env.py <service>/src      # every var the code reads
tk eval environments/wf-prod          # every var the deployment provides
```

Worth repeating whenever a service gains a dependency on an external API. The
failure mode this exists to catch is the one above: a feature that works in
every test, because tests supply the key, and cannot run in production.
