# WiseFood Usage Analytics, Activity Logging and Feedback Review — Audit and Plan

Date: 2026-09-04. Scope: every repo under `/mnt/workspaces/wisefood` (wisefood-api, wisefood-ui, foodchat, foodscholar, RecipeWrangler-Backend, wisefood-data-api, wisefood-client, platform-deployment, langfuse, core-components).

Goal: be able to answer, per user and per application, questions such as "trending recipe queries", "queries per user", "questions asked and feedback received", "token usage and cost per user", and give experts a console to review Q&A and feedback. The whole mechanism must be toggleable at platform, application and user level.

---

## 1. Summary

**What exists.** The raw material is partly there but nowhere readable:

- FoodScholar already persists every question with full answers, retrieved sources, pipeline metadata, `user_id` and `member_id` (`foodscholar.qa_requests`) and A/B or helpfulness feedback (`foodscholar.qa_feedback`). There is **no GET endpoint** for either table. The data is write-only.
- FoodChat persists sessions, messages, plans and thumbs feedback (`feedback` table). The only reader is the personalisation loop; no listing, export or aggregate exists.
- Langfuse is self-hosted, SSO-protected, wired into foodchat, foodscholar and the gateway, and the expert console already shows LLM cost, latency and traces from it.
- The gateway decodes identity once per request and forwards it downstream (headers to RecipeWrangler, HMAC member assertion to FoodChat, `user_id` in the body to FoodScholar).
- An append-only consent ledger (`wisefood.user_consent`) and a GDPR erasure path exist.
- Sentry (UI) and Prometheus+Grafana (APISIX only) exist. A dormant `engagement_index` schema for catalog ratings/comments exists in wisefood-data-api but is unwired.

**What is missing.** No service records a request-level activity event. No request or correlation id is ever set (`request.state.request_id` is read in three repos and written in none). Logs are plain text, `extra=` fields are discarded by the formatter, and there is no log aggregation. Search queries (recipes, catalog, autocomplete, question search) are forwarded and discarded everywhere; the only trace is one formatted `logger.info` line in RecipeWrangler. Token usage is not persisted anywhere outside Langfuse, and Langfuse's v2 metrics API no longer groups by user (high-cardinality dimensions are filter-only). The UI's global satisfaction widget is a mock that logs to the console. There is no analytics toggle, no analytics consent category, and no expert review entity.

**Recommendation.** Build a small, gateway-centred analytics subsystem rather than a new observability stack:

1. One **analytics schema in the platform Postgres** (`analytics.*`: events, search queries, LLM usage, unified feedback, expert reviews, runtime settings) with monthly partitions and nightly rollups.
2. One **ingest path**: the gateway records its own request and domain events in-process; downstream services and clients (browser, `wisefood-client` SDK) post batched events to two gateway endpoints (public `/analytics/events`, internal HMAC-signed `/internal/analytics/events`).
3. One **correlation key** (`X-Request-Id`) minted in the browser or SDK, forwarded through the gateway to every service and stamped into Langfuse trace metadata, so a UI action, a gateway request, a downstream call and an LLM trace join.
4. A **four-level toggle**: platform env flag, per-app and per-sink runtime settings editable by admins, per-user consent/opt-out, and capture-detail flags (raw query text, sampling).
5. A **console section** for experts: Q&A review with verdicts, feedback inbox, search insights, per-user activity and cost, and an expert action audit.

Langfuse stays the drill-down tool for traces and prompts; it is not the analytics store.

---

## 2. Audit: current state per repository

Legend: **present** / **partial** / **missing**.

| Repo | Request capture | Identity available | Durable activity storage | Read path for experts | Toggle |
|---|---|---|---|---|---|
| wisefood-api (gateway) | missing (only exception logs; `render()` logs on error only, `generic.py:113-144`) | present (`auth()` payload, `kutils.current_user`, member via `verify_member_access`) | missing (11 domain tables, only `user_consent` is a ledger) | partial (Langfuse metrics proxy, `routers/observability.py`) | partial (`GUEST_ENABLED`, `CACHE_ENABLED`, implicit Langfuse keys) |
| wisefood-ui | missing (no `track()`, no request-id; Sentry 20% traces, Flows.js walkthroughs) | present (Pinia auth + household stores) | localStorage search history only (`stores/recipe.ts`) | partial (console Observability tab, catalog stats) | partial (`flowsOrgId=''` kills Flows; no analytics flag) |
| foodchat | missing (plain `basicConfig`) | member only (HMAC assertion) | present: `sessions`, `messages`, `meal_plans`, `feedback` (`src/db.py`); no tokens/latency | missing (`db_get_feedback` has no caller) | Langfuse keys only |
| foodscholar | missing | present in body (`user_id`, `member_id`), no header/auth | present: `qa_requests`, `qa_feedback` (`src/models/db.py`), best-effort write that swallows errors | missing (no GET) | Langfuse keys only |
| RecipeWrangler-Backend | partial (one `logger.info` in `recipe_search`, `recipes.py:2143`) | headers defined (`api/identity.py`) but search/details handlers do not declare `get_caller` | missing (no interaction table; `recipe_events` index is spec only) | missing | pydantic settings, no analytics flag |
| wisefood-data-api | missing | present (JWT verified, used for authz + `creator` stamp) | missing (`engagement_index` schema unwired, `es_schema.py:926`) | missing | none |
| wisefood-client (SDK) | missing (no client header, no request id) | credentials only | n/a | n/a | none |
| platform-deployment | APISIX Prometheus on LLM egress only; nginx-ingress fronts users | Keycloak events **off** | Postgres `db` 5Gi, no backups, no analytics DB | Grafana with Prometheus datasource, one dashboard | `pim.libsonnet` is the right home for a platform flag |
| langfuse | traces from 3 services | `user_id` inconsistent (foodchat sends member_id, foodscholar sends sub or member_id) | ClickHouse, retention chart-managed | SSO UI for experts; gateway proxy | keys-present toggle |

### 2.1 Findings that shape the design

1. **Correlation is impossible today.** No `X-Request-Id` anywhere; `request.state.request_id` is read but never set in wisefood-api, RecipeWrangler and foodscholar. The FoodScholar `request_id` returned to the UI is a different, service-local id used only to key feedback.
2. **Identity is inconsistent across hops.** Gateway → RecipeWrangler: headers `X-User-Sub/Name/Roles` (RecipeWrangler's comment at `api/identity.py:33-38` claims they are not sent; verify, likely stale). Gateway → FoodChat: signed member assertion, no Keycloak `sub`. Gateway → FoodScholar: `user_id` in JSON. FoodChat → FoodScholar: `member_id` only, so in-chat nutrition questions land with `user_id = NULL`. `/foodscholar/qa/feedback` at the gateway does not stamp `user_id` at all (`routers/foodscholar.py:337`), and `qa_feedback` has no identity column.
3. **Langfuse cannot answer "tokens per user" as a report.** The v2 metrics API removed `userId` as a grouping dimension; it is filter-only. Per-user token and cost must be persisted by us. Also `langfuse_user_id` is member_id in foodchat and sub in foodscholar, so even filtering is inconsistent.
4. **Search text is discarded at five entry points.** `/recipes/search`, `/recipes/param_search`, `/api/v2/recipes/search`, `/api/v2/tools/find_recipes`, `/recipes/autocomplete`, plus catalog search in wisefood-data-api and FoodScholar `/search/summarize` (Redis-cached only). RecipeWrangler already computes normalized constraints, both latencies, `relaxed` and `lexical_fallback` flags; it formats them into a string.
5. **Zero-result detection is masked.** RecipeWrangler retries twice on an empty hit set before returning, so the returned `total` hides the original miss.
6. **Feedback has four unjoinable homes.** FoodChat SQLite/Postgres `feedback`, FoodScholar `qa_feedback`, the UI Likert widget (mock, `FeedbackButton.client.vue:83-95`), Sentry user feedback. No Langfuse scores are ever created (`create_score`: zero hits across repos).
7. **Expert actions are not audited.** Enrichment enqueue, corpus activation, recipe disable/enable, worker restart, guideline review approve/discard: authorised and forwarded, never recorded with who/when.
8. **Toggles do not exist**, and the consent ledger covers service provision only (`consent_type = service_data_processing`). There is no analytics category, no opt-out UI, no `analyticsEnabled` runtime flag.
9. **Ops posture.** Platform Postgres has a 5Gi PVC and no backups. No log aggregation, no OTel. CI is absent; deploys are manual. Production secrets are committed in `platform-deployment/wf-prod.yaml` and `langfuse/values.yaml`. Storing behavioural data raises the stakes on all of these.
10. **Structured logging is absent.** All five Python services use the same plain-text `dictConfig`; `extra={...}` fields (method, path, status, duration_ms, user) are silently dropped.

---

## 3. Target architecture

```
 Browser (wisefood-ui)            wisefood-client SDK / notebooks
   telemetry plugin                 telemetry hook + feedback API
   X-Request-Id, X-Client            X-Request-Id, X-Client
        │  batched events                  │  batched events
        ▼                                  ▼
 ┌──────────────────────────── wisefood-api (gateway) ─────────────────────────┐
 │ request_context middleware: request_id, user sub, roles, member, app, client │
 │ ActivityRecorder (async queue → Postgres)                                    │
 │   • request events for every authenticated call                             │
 │   • domain events at routers (search, view, favourite, save, feedback,      │
 │     expert action)                                                          │
 │ POST /analytics/events (public, auth any incl. guest, rate-limited)          │
 │ POST /internal/analytics/events (HMAC, services only)                        │
 │ GET  /analytics/**  (admin,expert) → console                                 │
 └───────┬──────────────────┬──────────────────┬───────────────────────────────┘
         │ X-Request-Id     │ X-Request-Id     │ X-Request-Id + user_id
         ▼                  ▼                  ▼
   RecipeWrangler        FoodChat           FoodScholar
   search event with     turn event with    qa.ask/qa.feedback events,
   normalized query,     tokens, latency,   new GET /qa/requests, /qa/feedback
   zero-result flags     feedback           llm.usage events
         └──────────────── llm.usage events (model, tokens, cost, sub) ────────┘
                                   │                       │
                                   ▼                       ▼
                    Postgres `db` schema analytics      Langfuse (traces, prompts,
                    events, search_query, llm_usage,    scores from feedback and
                    feedback, expert_review, settings,  expert verdicts; trace
                    daily_* rollups (CronJob)           metadata carries request_id)
                                   │
                                   ▼
                    Console "Insights" pages · Grafana Postgres datasource (ops)
```

### 3.1 Storage: `analytics` schema in the platform Postgres

Chosen over ClickHouse, Elasticsearch and Langfuse-only because it needs no new stateful service, joins directly with `wisefood.household_member` and `user_consent`, fits the gateway's existing SQLAlchemy/DDL pattern, and evaluation-phase volumes (thousands of users, tens of thousands of events per day) are well within Postgres with partitioning. Revisit ClickHouse if daily events exceed a few million.

Tables (new DDL file `wisefood-api/schemas/50_analytics.sql`, applied by hand on the live DB like the others):

| Table | Purpose | Key columns |
|---|---|---|
| `analytics.event` (range-partitioned by month) | Every activity event, request-level and domain-level | `id`, `occurred_at`, `received_at`, `request_id`, `client_session_id`, `user_id` (nullable), `member_id`, `household_id`, `is_guest`, `roles[]`, `app` (foodchat/foodscholar/recipewrangler/catalog/console/platform), `client` (ui/sdk/agent/internal), `event_type`, `route`, `method`, `status`, `duration_ms`, `locale`, `props` jsonb |
| `analytics.search_query` | One row per search, any surface | `request_id`, `user_id`, `app`, `surface` (recipes/param/catalog/tools/autocomplete/scholar_library), `raw_query` (nullable by capture flag), `normalized_query`, `query_hash`, `filters` jsonb, `result_count_first_pass`, `result_count_final`, `relaxed`, `lexical_fallback`, `latency_ms`, `zero_result` |
| `analytics.llm_usage` | One row per LLM call (or per turn, aggregated) | `request_id`, `trace_id`, `user_id`, `member_id`, `app`, `feature` (run_name), `provider`, `model`, `input_tokens`, `output_tokens`, `total_tokens`, `cost_usd`, `latency_ms`, `occurred_at` |
| `analytics.feedback` | Unified copy of every feedback signal | `request_id`, `user_id`, `member_id`, `app`, `target_type` (qa_answer/chat_message/recipe/guide/article/platform), `target_id`, `rating_kind` (thumbs/likert5/ab/helpful), `rating_value`, `reason`, `comment`, `source` (ui/sdk/service), `status` (new/triaged/resolved) |
| `analytics.expert_review` | Expert verdicts on Q&A and feedback | `reviewer_id`, `target_type`, `target_id`, `verdict` (correct/partially_correct/incorrect/unsafe/off_topic), `notes`, `tags[]`, `langfuse_score_id`, `created_at` |
| `analytics.settings` | Runtime toggles editable from the console | `key`, `value` jsonb, `updated_by`, `updated_at` |
| `analytics.daily_user_activity`, `daily_query_trend`, `daily_llm_usage`, `daily_feedback` | Rollups refreshed nightly (CronJob) plus on-demand refresh from the console | date, dimension columns, counts |

Retention: `ANALYTICS_RETENTION_DAYS` (default 365) drops old `event` partitions; rollups are kept indefinitely. Erasure: extend `erasure.purge_user` to delete `analytics.*` rows by `user_id` (or null the identity columns, keeping aggregates; decide with the DPO).

### 3.2 Identity and correlation

- **`X-Request-Id`**: generated by the browser telemetry plugin and the SDK (UUIDv7); the gateway generates one if absent, sets `request.state.request_id`, echoes it in the response header, and forwards it to every downstream call. Downstream services adopt it as their own request id, log it, and pass it as `langfuse_trace_id`/metadata so trace lookups from the console are one click.
- **User**: Keycloak `sub` everywhere. Standardise `langfuse_user_id = sub`, with `member_id` as a tag and in metadata. FoodChat → FoodScholar must forward `user_id`. The gateway must stamp `user_id`/`member_id` on `/qa/feedback` as it does on `/qa/ask`.
- **Member and household** resolved once per request by the gateway (reuse the two duplicated `verify_member_access` implementations, consolidated into one dependency) and attached to the request context so events carry them without extra Keycloak round-trips (`kutils.current_user` currently re-introspects per call).
- **Client**: `X-Client: wisefood-ui/<ver>`, `wisefood-client/<ver>`, `foodchat-agent`. Events carry `client` so agent-driven traffic (`/api/v2/tools/*`) does not pollute human trending queries.
- **Client session**: a per-tab session id from the UI plugin (sessionStorage) for funnels and dwell.

### 3.3 Toggles (four levels)

| Level | Mechanism | Effect when off |
|---|---|---|
| Platform | `ANALYTICS_ENABLED` in `platform-deployment/lib/pim.libsonnet` (next to the `guest` block), injected into every service and into the UI runtime config as `analyticsEnabled` | Middleware not installed, ingest endpoints return 204 without storing, UI plugin and SDK no-op, console Insights hidden with a notice |
| Application / sink (runtime, no redeploy) | `analytics.settings` keys: `apps.{foodchat,foodscholar,recipewrangler,catalog,console}`, `capture.raw_query_text`, `capture.client_events`, `capture.llm_usage`, `sinks.langfuse_scores`, `sample_rate`, `paused`; cached in Redis for 30 s; edited in console Platform Operations by admins; every change is itself an `admin.settings_changed` event | Events for that app/sink dropped at the recorder |
| User | New `consent_type = 'analytics'` rows in `wisefood.user_consent` plus a "Privacy & Data" toggle in `my-profile.vue`; the recorder checks a Redis-cached consent map | Events still counted for aggregates but `user_id`, `member_id`, `household_id`, `raw_query` set NULL; the user never appears in per-user views |
| Detail | `ANALYTICS_CAPTURE_QUERY_TEXT`, `ANALYTICS_SAMPLE_RATE`, `ANALYTICS_RETENTION_DAYS` env defaults, overridable in settings | Hashed queries only, sampled request events, shorter retention |

Guests are tracked under their ephemeral guest `sub` with `is_guest = true`; the guest reaper deletes or anonymises their rows.

### 3.4 Ingest contract

- `POST /api/v1/analytics/events` — auth any (guests included), body `{events: [{type, occurred_at, request_id?, client_session_id?, app, props}]}`, max 50 per batch, allowlisted `type` values, props size cap, `guest_budget("analytics")` rate limit. Identity comes from the token, never from the body.
- `POST /api/v1/internal/analytics/events` — services only, `X-WiseFood-Analytics-Signature` HMAC (same pattern as the FoodChat assertion secret), body may carry `user_id`/`member_id`/`request_id` because the caller is trusted.
- Shared Python module `telemetry.py` (template + runbook, same delivery model as `langfuse-integration-AGENT.md`): `emit(event)` pushes to an in-process bounded queue; a background task batches and posts; on overflow it drops and increments a counter; never raises into a request path; no-op when `ANALYTICS_ENABLED` is false or the secret is missing.

### 3.5 Event catalogue (initial)

| Event type | Emitted by | Key props |
|---|---|---|
| `http.request` | gateway middleware (sampled) | route template, method, status, duration_ms, client |
| `page.view`, `session.start` | UI plugin | path, referrer path, locale |
| `recipe.search`, `recipe.autocomplete` | RecipeWrangler (server truth) + UI (`useRecipes.searchRecipes`, for UI-side timing and abandonment) | normalized_query, filters, first_pass_count, final_count, relaxed, zero_result, latency_ms |
| `recipe.view`, `recipe.details_batch` | gateway `recipewrangler` router (before Redis cache) | recipe_id(s), region, source (search/plan/library) |
| `recipe.result_click` | UI | query_hash, recipe_id, rank |
| `favorite.add/remove`, `library.save/remove`, `recipe.adapt` | gateway entity layer | target urn/id |
| `catalog.search`, `catalog.view` | wisefood-data-api (via internal ingest) or gateway | index, query, result_count |
| `qa.ask`, `qa.answer`, `qa.stream_abandoned` | gateway foodscholar router + FoodScholar | qa_thread_id, mode, language, cache_hit, confidence, articles_consulted, latency_ms |
| `qa.feedback` | gateway (also written to `analytics.feedback`, mirrored as Langfuse score) | request_id, preferred_answer, helpfulness, reason |
| `chat.message`, `chat.plan_generated`, `chat.plan_saved`, `chat.tool_invoked`, `chat.memory_decision` | FoodChat orchestrator + gateway | session_id, intent, plan_id, turn latency |
| `chat.feedback` | gateway + FoodChat (mirrored to `analytics.feedback` and Langfuse score) | message_id, rating, comment |
| `llm.usage` | foodchat, foodscholar, RecipeWrangler constraint extractor | model, tokens, cost, feature, trace_id |
| `platform.feedback` | UI Likert widget, SDK | rating (1-5), comment, page |
| `expert.action` | gateway console routes | action (guideline.approve, recipe.disable, enrichment.enqueue, corpus.activate, worker.restart), target, reviewer |
| `expert.review` | console Q&A review | verdict, notes, target |
| `auth.login/logout/register` | Keycloak events (enable `eventsEnabled`, `adminEventsEnabled`), imported nightly from the `keycloak` schema the `wisefood` DB user can already read | client, ip class |
| `admin.settings_changed` | console | key, old, new |

---

## 4. Expert console: "Insights" section

New route group `/console/insights/**`, gated like the rest of the console (`expert|admin`), Unovis charts, `.client.vue` pattern, English like the other console pages (add a `console.*` i18n namespace only if the console is ever localised).

| Page | Answers | Data |
|---|---|---|
| Overview | DAU/WAU/MAU, guests vs registered, events per app, top features, feedback rate, negative-feedback rate, LLM cost per day | `daily_*` rollups |
| Q&A Review (the core ask) | Every question asked, from FoodScholar direct and from FoodChat nutrition turns, with answer(s), citations, pipeline meta, feedback received, Langfuse trace link; filters: date, app, language, has feedback, negative only, unreviewed; expert verdict form writes `expert_review` and a Langfuse `ANNOTATION` score; CSV export | `analytics.event` (`qa.*`) + new FoodScholar `GET /qa/requests`, `GET /qa/requests/{id}` proxied under `auth("admin,expert")` |
| Feedback Inbox | All feedback across apps in one triage list (new/triaged/resolved), grouped by target | `analytics.feedback` |
| Search Insights | Trending queries (last 7d vs previous 7d), top queries, rising queries, zero-result queries, filter usage, most viewed/saved/favourited recipes, guides and articles | `search_query`, `event` |
| Users | Per-user activity (queries, questions, chat turns, feedback given), tokens and cost per user, cohort filters (guest, country, age group via member profile join), drill-down timeline; respects opt-outs | `daily_user_activity`, `llm_usage` |
| LLM Usage | Tokens and cost per app, feature, model, user; keeps the existing Langfuse panels for latency and traces | `llm_usage` + existing observability proxy |
| Expert Activity | Who approved/discarded which guideline rule, disabled which recipe, enqueued which batch, when | `event` (`expert.*`) |
| Platform Operations (admin) | Analytics toggles: master pause, per-app, capture flags, sample rate, retention; recorder health (queue depth, drops, last flush) | `analytics.settings`, `/analytics/health` |

Gateway read API for the console: `GET /api/v1/analytics/overview`, `/analytics/queries/trending`, `/analytics/queries/zero-result`, `/analytics/qa`, `/analytics/qa/{request_id}`, `/analytics/feedback`, `/analytics/users`, `/analytics/users/{sub}`, `/analytics/llm-usage`, `/analytics/expert-activity`, `POST /analytics/reviews`, `GET|PUT /analytics/settings`, `GET /analytics/export.csv?...`. All `auth("admin,expert")`, settings `auth("admin")`.

---

## 5. Client-side and SDK

**wisefood-ui**

- New `app/plugins/04.telemetry.client.ts` (after Keycloak init) exposing `useTelemetry().track(type, props)`; batches to `/analytics/events` every 5 s or 20 events, flushes on `visibilitychange`/`pagehide` via `sendBeacon`; no-op when `analyticsEnabled` is false or the user opted out.
- Add `X-Request-Id` and `X-Client` in the four HTTP clients (`wisefoodRestApi.ts`, `wisefoodApi.ts`, `foodchatApi.ts`, `recipeApi.ts`), or better, extract the duplicated fetch/auth/401-refresh/envelope logic into one `app/utils/httpClient.ts` and hook there; record client-side latency and status there.
- Semantic events at the existing chokepoints: `useRecipes.searchRecipes/searchRecipesByParams`, `useFoodScholarQaStream.ask`, `stores/foodchat.ts sendMessage`, router `afterEach` for page views, result-card click handlers.
- Wire `FeedbackButton.client.vue` to `POST /analytics/feedback` (platform Likert).
- "Privacy & Data" section in `my-profile.vue` between Memory and Danger Zone: analytics consent toggle, link to `/privacy`; update the privacy page text; en/hu/sl keys added in parity.
- Console Insights pages as in section 4.

**wisefood-client (Python SDK)**

- Both `Client` and `DataClient`: send `X-Client: wisefood-client/<version>` and a per-call `X-Request-Id`; return the request id on the response wrapper so notebook users can reference it.
- `client.analytics.track(type, props)` and `client.feedback.submit(target_type, target_id, rating, comment, request_id=None)` calling the public ingest endpoints; batched in a background thread with `flush()` and `atexit`.
- Opt-out via `WISEFOOD_TELEMETRY=0` or `Client(..., telemetry=False)`; document in README and AGENTS.md.
- `foodscholar-lib` notebooks and any evaluation scripts use the same path, so expert evaluation runs land as `client = sdk` events and their feedback shows in the inbox.

---

## 6. Phased plan

Effort assumes one to two developers. Each phase is independently deployable and useful.

### Phase 0 — Foundations and quick wins (weeks 1–2) — IMPLEMENTED 2026-09-04

Status per item is recorded at the end of this section. One design decision changed
during implementation; see "Identity for chat-originated questions" below.

Repos: all Python services, ui, platform-deployment, core-components.

1. Request-id middleware in wisefood-api, foodchat, foodscholar, RecipeWrangler, wisefood-data-api: accept/generate `X-Request-Id`, set `request.state.request_id`, echo it, forward it in every downstream client (`backend/foodchat.py`, `backend/foodscholar.py`, `backend/recipewrangler.py`, foodchat `foodscholar_service.py`).
2. Structured JSON logging in the shared `logsys.py` (python-json-logger) with `request_id`, `user_sub`, `route`, `status`, `duration_ms`; make `render()` log successes at INFO when `ANALYTICS_ENABLED`.
3. `ANALYTICS_ENABLED` in `pim.libsonnet`, injected in all service libsonnets and the UI runtime config; `.env.example` updates everywhere.
4. Identity fixes: FoodChat forwards `user_id` to FoodScholar; gateway stamps `user_id`/`member_id` on `/qa/feedback`; `qa_feedback` gains `user_id`/`member_id` columns; RecipeWrangler search/details/autocomplete handlers declare `Depends(get_caller)`; verify the stale "gateway does not forward" comment in `api/identity.py`.
5. Standardise Langfuse: `langfuse_user_id = sub`, `member_id` tag, `request_id` in metadata, in foodchat and foodscholar; add `create_score` in both feedback handlers (thumbs → boolean score, A/B → categorical, helpfulness → numeric).
6. Enable Keycloak login/admin events in `keycloak-init/run.py configure_realm_settings` with an expiration.
7. Wire `FeedbackButton.client.vue` to a real endpoint (lands in Phase 1's `analytics.feedback`; until then, to a Langfuse score or a temporary table).

Exit: every log line across services carries the same request id for one user action; feedback appears as scores in Langfuse; toggle flips cleanly with no errors.

**Delivered (2026-09-04).**

| Item | Status | Where |
|---|---|---|
| Correlation id assigned, echoed, forwarded | done | `wisefood-api/src/context.py`, `src/middleware.py`; adopted by the other four services via the vendored `obs_context.py` |
| Structured JSON logging, `extra` preserved | done | `LOG_FORMAT=json` in all five services; text mode now also carries the request id |
| `ANALYTICS_ENABLED` plumbing | done | `platform-deployment/lib/pim.libsonnet` `observability` block, injected into all five services; gateway `Config` reads it |
| Gateway stamps identity on `/qa/feedback` | done | `src/routers/foodscholar.py`; `qa_feedback` gained `user_id`, `member_id`, `correlation_id` |
| FoodChat → FoodScholar attribution | done, by correlation rather than by user id (see below) | `foodchat/src/services/foodscholar_service.py`, `foodscholar` `qa_requests.correlation_id` |
| Keycloak login/admin events | done | `core-components/keycloak-init/run.py`, 90-day retention, `KEYCLOAK_EVENTS_EXPIRATION` |
| Langfuse `create_score` from feedback | **not done** | Needs a stable Langfuse trace id per QA turn, which nothing captures today; see "Open" below |
| UI satisfaction widget wired to a real endpoint | **not done** | Deliberately deferred to Phase 1, when `analytics.feedback` exists to receive it |
| RecipeWrangler search handlers take `get_caller` | **not done** | Moved to Phase 2 with the search events that need it |

Two improvements were made that the plan did not call for, because the middleware
was being rewritten anyway:

* Token introspection ran **inline on the event loop for every authenticated
  request**, with no cache. It now runs off the loop with a 30-second cache, the
  same trade-off `auth._introspect_active` already accepts. Failures are cached
  too, so an invalid token cannot be used to hammer Keycloak.
* The middleware is **pure ASGI** rather than `BaseHTTPMiddleware`. The latter
  runs the app in a child task, so a value set by a route is not visible when the
  middleware regains control — which is exactly what the Phase 1 recorder needs in
  order to learn which member a request acted on.

**Identity for chat-originated questions — decision changed.** The plan said
FoodChat should forward `user_id` to FoodScholar. It cannot honestly do so:
FoodChat receives a signed *member* assertion, not a Keycloak subject, and adding
the subject would mean either extending the signed assertion format (a breaking,
coordinated change across two services) or forwarding an unsigned, spoofable
identity. Instead the **correlation id** is forwarded and persisted on
`qa_requests.correlation_id`, and the user is resolved by joining the gateway's
activity record for the same id. This is strictly better: identity is resolved
once, at the only tier that can verify it, and a service gains no identity it has
no business holding. `qa_requests.user_id` therefore stays NULL for
chat-originated questions by design, and the Q&A Review page joins on
`correlation_id`.

**Open — Langfuse feedback scores.** `create_score` accepts `trace_id` or
`session_id`. Scoring by `session_id` (FoodScholar's `qa_thread_id`) is available
today but coarse: one thread holds many answers, and feedback is per answer.
Scoring by `trace_id` is what the console needs, and no code captures a trace id
per QA turn — in the v3 OTel-based SDK `get_current_trace_id()` only returns one
inside an active span, and the LangChain callback's spans close when `.invoke()`
returns. The fix is to wrap a QA turn in an explicit Langfuse span and persist
`qa_requests.langfuse_trace_id`. That needs a live Langfuse to verify, and this
deployment has already lost every trace once to an unverifiable config change, so
it was not written blind.

### Phase 1 — Event store and gateway capture (weeks 2–4) — IMPLEMENTED 2026-09-04

Repo: wisefood-api, platform-deployment.

1. `schemas/50_analytics.sql` with the tables in 3.1; SQLAlchemy models in `sql.py`; entity layer `api/v1/analytics.py`.
2. `request_context` middleware replacing `rw_identity_middleware`: decode once, resolve member/household lazily, populate context used by proxies and the recorder.
3. `ActivityRecorder`: bounded asyncio queue, batch insert, drop-on-overflow with a counter, `/analytics/health`.
4. Domain events at gateway routers: recipe view/details/search (proxy layer), favourites, saved items, adapted recipes, qa ask/feedback, chat message/feedback, expert actions on all `auth("admin,expert")` proxies.
5. Consent type `analytics` in the ledger and `users/me/consent` API; recorder honours it. Erasure extended.
6. Ingest endpoints (public + internal) with validation and rate limits; `analytics.settings` with Redis cache; admin `GET|PUT /analytics/settings`.
7. Increase the `db` PVC (5Gi is too small) and add a nightly `pg_dump` CronJob to MinIO before any behavioural data lands.

Exit: "queries per user" and "trending recipe queries" answerable by SQL from gateway-observed traffic; unit tests for recorder no-op when disabled, consent stripping, allowlist validation.

**Delivered (2026-09-04).** 67 new tests; the DDL and the recorder were both
exercised against a real PostgreSQL 17.6 before being called done.

| Item | Status |
|---|---|
| `schemas/50_analytics.sql` (6 tables, 20 indexes) | done, applied twice against a live Postgres to prove idempotency |
| ORM models in `src/sql.py` | done, verified column-for-column against the applied DDL |
| Recorder with bounded queue, batching, drop counters, `/analytics/health` | done |
| Analytics consent type, recorder honours it, erasure extended | done |
| Ingest endpoints (public + HMAC-signed internal), runtime settings, admin settings API | done |
| `http.request` emission from `render()` | done |
| Domain events at individual routers | **not done** — the envelope decorator covers all 145 enveloped routes generically; per-route semantic events are better added with the Phase 2 service-side events they pair with |
| Postgres volume increase and nightly dump | **not done** — an infrastructure change to a live cluster, listed under "before enabling" below |

**Storage decision changed — no partitioning.** The plan called for monthly range
partitions. The table is plain, with time-ordered indexes and delete-based
retention. Declarative partitioning has a specific failure mode — once rows land
in a DEFAULT partition, creating the real partition for that range fails and the
fix is a manual data move — and this platform has no migration tooling, no CI
and no scheduled DDL, so nobody is positioned to handle it. At the volumes this
is sized for (order 10^4 events/day) one indexed table is comfortable. The
column layout is partition-ready for when daily volume reaches the millions.

**Two bugs found by testing, both fixed.**

* *Shutdown lost a batch.* The drain worker spends most of its life holding a
  partly-assembled batch, waiting out the flush interval. Stopping cancelled the
  task, discarding it — up to 200 events lost on every pod restart, silently,
  with the stats still reading zero errors. It is now asked to finish through
  the queue, and cancellation is only the fallback.
* *The signed ingest ignored the identity it was given.* The endpoint documented
  that a platform service may report activity on another party's behalf, but the
  recorder always took identity from the request context — which, for a
  service-to-service call, names nobody. Identity from a signed body is now
  honoured; the public endpoint still cannot set it.

**Consent semantics worth knowing.** Consent is evaluated when a batch is
*written*, not when an event is recorded, and that leans conservative in both
directions: withdrawing covers events still in the queue, granting does not
reach back into it. The window is one flush interval.

**Before enabling in production**

1. Apply `schemas/50_analytics.sql` by hand (`psql -v ON_ERROR_STOP=on -f`), as with every other schema file.
2. Grow the `db` volume beyond 5Gi and add a nightly dump. Neither exists today, and behavioural data raises the cost of the gap.
3. Decide decision 3 below (opt-in vs opt-out) and set `ANALYTICS_CONSENT_MODE` accordingly. It defaults to `opt_in`.
4. Create the `analytics-ingest-secret` only when a downstream service is ready to report; absent, the internal endpoint stays closed.
5. Then set `ANALYTICS_ENABLED: true` in `lib/pim.libsonnet`.

### Phase 2 — Service-side truth and LLM usage (weeks 4–6) — IMPLEMENTED 2026-09-04

Repos: RecipeWrangler, foodchat, foodscholar, wisefood-data-api.

1. Shared `telemetry.py` template + runbook; vendored into each service (the Langfuse runbook model).
2. RecipeWrangler: `normalize_query()` helper; emit `recipe.search` from `recipe_search`, `param_search`, catalog search, `find_recipes`, `browse`, `autocomplete` with first-pass and final counts, `relaxed`, `lexical_fallback`, `elapsed_ms`/`es_took_ms` from `search_recipes_es`; emit `llm.usage` from the constraint extractor.
3. FoodChat: emit `chat.message` per turn with intent, plan id, turn latency; `llm.usage` per LLM call from the LangChain callback (`usage_metadata`), aggregated per turn with `sub`; `GET /feedback` (admin) listing.
4. FoodScholar: make `_persist_request` failures visible (metric + WARNING with request_id); add `GET /qa/requests` (filters: date, user, member, language, has_feedback, mode), `GET /qa/requests/{id}`, `GET /qa/feedback`; emit `qa.answer` and `llm.usage` events; add `request_id` (gateway id) column to `qa_requests`.
5. wisefood-data-api: emit `catalog.search`/`catalog.view` via internal ingest; optionally wire the dormant `engagement_index` for guide/article ratings, or route those through `analytics.feedback` instead (recommended: the latter, one feedback home).
6. Gateway proxies for the new read endpoints under `auth("admin,expert")`.

Exit: token and cost per user per app queryable; zero-result queries visible with the pre-relaxation count; every FoodScholar question retrievable by id from the gateway.

**Delivered (2026-09-04).** 3,208 tests pass across the five repos. The loop was
verified end to end against a live gateway and PostgreSQL: RecipeWrangler sent a
search, an LLM-usage record and a view event over signed HTTP, and all three
landed in `analytics.*` with the caller attributed.

| Item | Status |
|---|---|
| Shared `wf_telemetry.py`, vendored into all four services | done — stdlib only, bounded queue, background thread, drops rather than retries |
| RecipeWrangler search events on all six surfaces | done — `/recipes/search`, `param_search`, catalog `search` and `browse`, agent `find_recipes`, `autocomplete` |
| Pre-relaxation result count | done — captured before the two retries that previously hid the miss |
| RecipeWrangler LLM usage | done — usage callback on the constraint extractor's pooled client |
| FoodChat turn events and token accounting | done — `chat.turn` per turn; usage callback at the Groq pool, beside the Langfuse handler |
| FoodChat feedback readable | done — `GET /foodchat/members/{id}/feedback`, member-scoped (see below) |
| FoodScholar review read path | done — `GET /qa/requests`, `/qa/requests/{id}`, `/qa/feedback/list` and a `QAReviewService` with filters for user, member, correlation id, language, free-text search, has-feedback and negative-only |
| FoodScholar persistence failures surfaced | done — consecutive-failure counter, structured error, `qa.persist_failed` event; an outage no longer looks like nobody asking questions |
| Catalog search events | done — instrumented at `Entity.search`, one chokepoint for all ten entity types; the verified caller is recorded where the token is actually checked |
| Gateway proxies for the review endpoints | done — `auth("admin,expert")`, every read audited |

**Feedback mirroring.** Each service keeps its own feedback table where it drives
behaviour — FoodChat's still feeds personalisation — and mirrors to
`analytics.feedback`. That is what turns four unjoinable tables into one
reviewable inbox.

**A guard test changed a design.** The gateway asserts that every proxy naming a
member authorises that member. A proxy exposing one member's chat feedback to
experts cannot satisfy that, and an exception would weaken the invariant for the
one route that wanted it. The proxy was dropped: experts use the feedback inbox,
which is better anyway — reading FoodChat's table directly returns comments
regardless of whether their author consented to analytics, and the inbox applies
consent. FoodChat's own endpoint stays, member-scoped and assertion-guarded, and
was added to that repo's route-authorization audit.

---

### Tracing: an application-side kill switch

Tracing used to be a deploy-time fact — it ran if the Langfuse keys were set, and
stopping it meant unsetting them and rolling every pod. That is impossible while
an incident is in progress, and impossible when a study participant withdraws
mid-session.

Two settings now control it platform-wide, editable from the console:
`tracing.enabled` (master) and `tracing.langfuse` (that sink alone). Services
poll `GET /api/v1/analytics/runtime-flags`, signed with the ingest secret, every
30 seconds, and each service's Langfuse module consults the result before handing
out a callback handler. Verified end to end: an admin change, no redeploy, the
service stops.

Three details matter, and each was a way to get this quietly wrong.

* **The accessor must not be cached.** `get_callback_handler` was `@lru_cache`d,
  which would pin the first answer for the life of the process and make the
  switch appear to do nothing. Construction is still cached; the switch check is
  not. The existing `cache_clear()` contract was preserved rather than renamed at
  every call site.
* **It must not take prompt management down.** The same Langfuse client serves
  the prompt registry, so gating it would silently drop every prompt back to its
  in-code fallback. Only the callback handler — the thing that emits traces — is
  switched.
* **It must fail open.** A service that cannot reach the gateway keeps tracing. A
  control plane that failed closed would stop tracing on every gateway hiccup.

### Trace authorization

Raw Langfuse traces are now **admin only**; they were admin-or-expert. A trace
carries the prompt a person typed, the model's answer and every intermediate
agent call, for whoever was using the platform — that is the content of other
people's conversations, and "expert" is a role granted for curating the corpus.

The dashboard endpoint also bundled 25 raw traces, so restricting `/traces` alone
would have moved the door rather than closed it. It now omits them for
non-admins and says so, instead of showing an empty panel that looks like a
broken query. Aggregates — counts, cost, tokens, latency — stay admin+expert,
since they carry no user content and an expert needs them.

Experts review answer quality through the Q&A endpoints, which are scoped to
questions asked of FoodScholar and carry consent-aware identity. Every read of
raw traces or of the review surface is recorded as `admin.traces_read`,
`expert.qa_reviewed` or `expert.feedback_reviewed` — the audit trail the platform
has never had.

### Sessions: the id in the footer

A user sees a short, readable session reference in the page footer
(`k3f9-2xa7-lm4q`), so "it gave me a strange answer earlier" becomes something
an expert can actually look up. The browser mints it, sends it as
`X-Client-Session`, and every recorded row carries it — not just `event`, but
`search_query`, `llm_usage` and `feedback` too, so "how many searches in this
session, and how many found nothing" is one predicate rather than a join.

`GET /api/v1/analytics/sessions/{id}` returns named counts (searches, questions
asked, meal plans generated and saved, recipes viewed, feedback given, tokens
and cost) plus an ordered timeline. It is **admin and expert only**, as is
`/analytics/sessions`. What a normal user gets is the id itself, which is
useless to anyone who cannot query it — two users cannot read each other's
sessions by guessing an id, because neither can read sessions at all.

The id is deliberately not an identity:

* it lives in `sessionStorage`, so it dies with the browser tab;
* it resets after 30 minutes of inactivity, so an id left open overnight does
  not merge yesterday's activity into today's;
* it resets when the signed-in user changes, so one id can never span two
  accounts and link them to each other;
* the alphabet excludes `0`, `1`, `i`, `l` and `o`, because the whole point is
  that someone reads it off the screen and types it into a support form.

The rules live in one pure function (`resolveSession`) that takes the clock, the
current user and the stored value and returns what the session should be, so
they can be exercised without a browser. Seventeen cases are covered, including
a clock that jumps backwards.

### Phase 3 — Clients (weeks 5–7, overlaps Phase 2) — PARTIALLY IMPLEMENTED 2026-09-04

**Delivered.** The browser now sends `X-Request-Id`, `X-Client` and
`X-Client-Session` on every call, through all four HTTP clients plus the one
page that calls the gateway directly. Page views come from a router hook;
searches and questions are emitted from the composables that already know they
happened, because a router hook cannot tell a search that returned nothing from
one that was never run. The satisfaction widget, which had been logging every
rating to the browser console and discarding it, now posts to
`/analytics/feedback`. A Privacy & Data section in the profile page carries the
analytics consent switch — without it the opt-in default means nothing is ever
attributed. Footer, privacy and profile strings are in en, hu and sl with key
parity checked (1,396 keys each).

**A pre-existing bug fixed on the way.** All ten `fetch` calls in the two
envelope clients spread `...fetchOptions` *after* `headers`, so any caller
passing its own headers replaced the merged object wholesale — dropping
`Authorization` with it. The new headers would have inherited the same fault.

**Not done.** The `wisefood-client` SDK, and the semantic events for library
saves, favourites and result clicks.



Repos: wisefood-ui, wisefood-client.

1. UI telemetry plugin, `X-Request-Id`/`X-Client` in the HTTP clients (or the unified `httpClient.ts`), semantic events at the chokepoints, page views, result clicks, stream abandonment.
2. Privacy & Data toggle in my-profile, privacy page text, i18n parity en/hu/sl.
3. SDK telemetry + feedback API, opt-out, docs, changelog, version bump; update `foodscholar-lib` notebooks to use it.

Exit: a browser search appears as one `recipe.search` from the server and one `recipe.result_click` from the client, joined by request id; SDK feedback from a notebook shows in the inbox.

### Adversarial audit, 2026-09-04

Three independent reviewers went over every uncommitted change with instructions
to find defects rather than confirm the work. They found real ones. Everything
below is fixed and covered by a test, except where noted.

**Bugs that made a feature silently not work**

* *The tracing kill switch did not reach a running service.* The Langfuse
  handler is attached when a pooled model client is built, and that client then
  lives for the process's lifetime. Returning `None` from the accessor while the
  switch was off therefore only affected clients built *after* the flip — every
  warm pool kept tracing, and a service that booted with tracing off could never
  be switched on. The switch appeared to work and did nothing. A wrapper handler
  is now attached instead; it checks the switch on every callback. The test that
  "proved" the fix earlier tested the accessor, not the pooled client, so it
  passed throughout.
* *Every event recorded from a request handler had no route.* The middleware set
  the route on the way out, after the handler had finished, so searches,
  questions and the request record itself all fell into the `platform` bucket.
  Every per-app report was wrong while looking healthy.
* *The exclusion list never matched in production.* It compared
  `request.url.path` against `/api/v1/...`, but the service runs behind a
  `/rest` root path, so real traffic never matched and the ingest endpoints
  recorded their own traffic. It passed in tests, which run without the prefix.
  Matching is now on the route template, which never carries a root path.
* *`app_for_route` matched substrings*, filing `/users/me/analytics-consent`
  under `console`. Now matched on path segments.
* *Failures were not recorded, despite a comment claiming they were.* `render()`
  wraps only the handler body, so a 401 from the auth dependency, a 429 from the
  guest budget and a 422 from validation were all invisible, as were streaming
  responses. Recording moved to the middleware, the one place that sees every
  response.
* *`household_id` was a column the recorder always wrote as `None`*, while the
  ownership check had the household in hand.
* *FoodChat reported one turn entry point out of four*, and only on success.
  Reporting moved to the guard all four share, which also sees refused, capped
  and failed turns.
* *A regression in the minikube environment*: a new secret reference was added
  to a library that environment evaluates, without the matching mapping. It no
  longer evaluated at all. (That environment has a separate, pre-existing break
  in `sysinit.libsonnet` referencing `images.API`, unrelated to this work.)

**Resilience**

* *One bad field from one service erased up to 200 rows belonging to everyone.*
  A single over-long session id or a token count of `"n/a"` failed the whole
  multi-row INSERT, and the recorder drops a failed batch by design. Values are
  now coerced to their column, and a failed batch is retried row by row so one
  bad row costs one row.
* *A paused replica could never see itself un-paused.* Settings were refreshed
  only after dequeuing an event, and a paused replica admits none. The worker
  now refreshes when idle.
* *A Keycloak blip blinded a signed-in user for 30 seconds*, because failed
  introspection was cached as long as success. Failures now expire in 3 seconds.
* *`Telemetry.stop()` kept accepting events*, and its final drain sent at most
  one batch and discarded the rest uncounted.
* *The first flag fetch blocked service startup* on the main thread.

**Privacy**

* *RecipeWrangler shipped health data to analytics.* The reported search filters
  were built from the whole constraint set, which carries the member's
  allergies, dietary groups and liked ingredients — keyed to their user id, and
  precisely what the platform's own tracing policy forbids. Filters are now
  allowlisted, so the next field added to the search payload is not reported by
  default.
* *Free text survived stripping in two places*: `feedback.comment`, and anything
  a client put in `event.props`. Both are now cleared with identity, and erasure
  clears them too.
* *Erasure missed tables and raced the queue*: expert reviews and settings kept
  a subject, all four updates shared one transaction, and the consent cache was
  not invalidated so queued events could still be written attributed.
* *A stripped row is pseudonymous, not anonymous.* `request_id` is retained
  because it is the operational key that joins to service logs, and those carry
  the subject regardless of analytics consent, so an administrator with both can
  re-identify. This is now stated in the schema rather than implied otherwise.

**The browser could log you out**

Telemetry posted through the shared API client, whose 401 handling refreshes the
token and, failing that, signs the user out and redirects. A background batch of
page views could therefore bounce someone to the login screen from a page that
made no API calls of its own. Telemetry now uses its own request, where a 401 is
just a dropped batch, with `keepalive` so the final flush survives the page
going away.

**Tests that would have passed while the feature was broken**

Three: one asserted on an attribute that does not exist, one passed in any
environment, and one tested the accessor rather than the behaviour. All three
were rewritten to assert the real property.

**Also fixed**: settings validation accepted `sample_rate=true` and
`apps={"x":"false"}` (a string, so truthy — collection stayed on while the admin
believed it was off); an unknown QA request returned 400 rather than 404; the
data catalog reported page size instead of hit count; search latency omitted the
LLM extraction the user waited for; failed searches went unrecorded, making an
outage look like nobody searching; a non-ASCII signature digest raised a 500
instead of a 401; the platform feedback endpoint had no rate limit; the footer
used an icon set the project does not install; a failed consent load showed
"off" to a user who was actually opted in.

**Known and accepted**: JSON logs carry the user subject on every line
regardless of analytics consent — operational logs sit outside the consent model
and have their own retention, but they are a third store erasure does not reach.
Consent invalidation is process-local, so on a multi-replica deployment a
withdrawal reaches other replicas within the consent TTL, now 30 seconds rather
than 5 minutes. Signed ingest batches are replayable within their 300-second
window; a nonce would fix it if duplicate rows ever matter.

### Phase 4 — Expert console Insights — IMPLEMENTED 2026-09-04

The console's existing Analytics page is now the hub, with **Usage** as its
first tab, ahead of Content and Observability. That was deliberate: the question
people open this page to answer is whether the product is working for anyone,
and it used to lead with catalogue counts.

**The page leads with decisions, not totals.** A "Needs attention" panel sits
above the numbers. Each row is a count and the button that acts on it: searches
that found nothing and the query most responsible, negative comments nobody has
read, criticised answers with no expert verdict, sessions that cannot be
attributed. A number with no action attached is decoration, so the panel is
generated server-side from the same queries the pages use, not assembled in the
browser from whatever happened to be loaded.

**Every headline figure carries its direction of travel** against the previous
equal period, and the colour means something: searches rising is good, searches
finding nothing rising is not, and a tile that paints both green teaches people
to ignore the colour.

Pages, all admin+expert, all reads audited:

| Page | What it is for |
|---|---|
| Analytics › Usage | Attention items, deltas, activity over time, actions by product, and previews of the four things worth chasing |
| Search insights | Top, rising and zero-result queries. "Rising" compares against the previous window, so a query that ran twice yesterday and forty times today surfaces above one that has run forty times a day for a month |
| Q&A review | Every question, its answer, its sources, its feedback — and a verdict form. One verdict per reviewer per target, so revisiting is changing your mind rather than adding a second opinion |
| Feedback inbox | Every surface's feedback in one triage list, new → read → resolved, with a jump straight to the answer being complained about |
| People & sessions | Per-person activity and cost, plus a lookup box for the reference a person reads off their footer |
| Session detail | One session at `/console/insights/sessions/{id}`: counts, spend, and an ordered timeline. Addressable by id, because a reference nobody can paste anywhere is not a reference |
| Model usage | Tokens and spend by model, product, feature and person — the per-user cut Langfuse cannot produce |
| Expert activity | Who used their privileges and on what, including who read the userbase's questions |
| Platform Operations | The runtime switches and recorder health, admin only |

**Retention** runs as a nightly CronJob on the API image
(`scripts/apply_analytics_retention.py`), deleting in batches so a first run
over a year of data does not hold one long lock. Feedback is never deleted:
somebody wrote it on purpose and an expert may not have read it.

### Phase 3 — the SDK — IMPLEMENTED 2026-09-04

`wisefood-client` now reports usage, because a meaningful share of platform
activity is partners and evaluation notebooks driving the API directly, and
without it every usage report silently meant "usage through the browser".
`client.analytics.track(...)` and `client.feedback.submit(...)`, both carrying
`X-Request-Id`, `X-Client` and a session id. Queued on a background thread, so
it never blocks or raises into a caller; it sends no arguments and no results;
it switches itself off against a gateway that does not accept it; and
`WISEFOOD_TELEMETRY=0` or `Client(..., telemetry=False)` turns it off outright.

Two defects the end-to-end test against a live gateway caught: `flush()` stopped
the reporter despite promising to keep going, so everything a script did after
flushing was silently discarded; and the per-event product was ignored, so every
SDK event landed under `platform` and per-product reports undercounted.

### Phase 4 — Expert console Insights (weeks 6–9) — original plan

Repos: wisefood-api (read API), wisefood-ui.

1. Read API endpoints listed in section 4 with pagination and CSV export.
2. Rollup CronJob (`platform-deployment` Job/CronJob running a gateway management command) and on-demand refresh.
3. Pages: Overview, Q&A Review with verdicts (writes `expert_review` and Langfuse `ANNOTATION` score), Feedback Inbox, Search Insights, Users, LLM Usage, Expert Activity, toggles in Platform Operations.
4. Grafana Postgres datasource pointing at `analytics` (read-only role) and one ops dashboard (recorder drops, events/min, ingest errors).

Exit: an expert can open a negative-feedback question, read the answer and sources, record a verdict, and see it as a score on the Langfuse trace, without leaving the console.

### Phase 5 — Hardening (weeks 9–10)

1. Retention job dropping old partitions; anonymisation of guest rows after the guest TTL.
2. Load test the recorder at 50× expected traffic; decide whether ClickHouse is warranted.
3. Move secrets out of git (`wf-prod.yaml`, `langfuse/values.yaml`) into sealed secrets or an external secret store; pin the Langfuse chart version.
4. Minimal CI (lint + unit tests) for the repos touched, so the analytics contract does not drift.
5. Privacy documentation: data inventory, retention, legal basis, DPIA note for the evaluation phases.

---

## 7. Decisions needed from the team

1. **Store now, or ClickHouse from day one.** Recommendation: Postgres `analytics` schema now, partitioned; ClickHouse only if volume demands.
2. **Raw query text retention.** Recommendation: store raw text for consenting users with 180-day retention, hash-only for opted-out users and guests after TTL. Confirm with the project's data protection lead.
3. **Consent model.** Opt-out with notice (default on) versus opt-in. For an EU project in evaluation phases, opt-in via the existing consent bar (a second checkbox, `consent_type = analytics`) is the safer default; opt-out is more data. Recommendation: opt-in for registered users, anonymous aggregate-only for guests.
4. **Erasure semantics.** Delete analytics rows on account erasure, or null identity and keep aggregates. Recommendation: null identity columns, keep counts.
5. **SDK telemetry default.** On with an env opt-out (recommended, the SDK is used by project partners), or off by default.
6. **Where FoodChat feedback lives long-term.** Keep FoodChat's own table as the recommendation-loop source and mirror to `analytics.feedback` (recommended), or move it entirely.

---

## 8. Immediate next steps

1. Agree on decisions 1–3 above.
2. Start Phase 0 in wisefood-api: request-id middleware, JSON logging, `ANALYTICS_ENABLED` plumbing, `/qa/feedback` identity stamp, Langfuse scores from both feedback handlers.
3. In parallel, enable Keycloak events and fix FoodChat → FoodScholar `user_id` forwarding.
4. Draft `50_analytics.sql` for review before Phase 1 starts.
