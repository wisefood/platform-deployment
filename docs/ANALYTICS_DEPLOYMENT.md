# Deploying WiseFood analytics

Ships **off**. Nothing in this change records anything until step 7, so every
step before it is safe to do during normal working hours and safe to stop after.

Repos touched: `wisefood-api`, `foodscholar`, `foodchat`, `RecipeWrangler-Backend`,
`wisefood-data-api`, `wisefood-ui`, `wisefood-client`, `platform-deployment`,
`core-components`.

---

## Before you start: three decisions

| Decision | Default if you say nothing | Where |
|---|---|---|
| Opt-in or opt-out consent | `opt_in` — activity is counted, nobody is named until they agree | `ANALYTICS_CONSENT_MODE` in `lib/pim.libsonnet` |
| Keep the text people type into search boxes | yes, for consenting users only | `capture.raw_query_text`, changeable later from the console |
| How long to keep activity | 365 days | `ANALYTICS_RETENTION_DAYS` in `lib/pim.libsonnet` |

Under `opt_in`, **reports will look empty of people until users start agreeing.**
Totals are correct from day one; the per-person views fill up as consent comes in.
That is the setting working, not a fault.

---

## 1. Grow the database volume and take a backup

The platform Postgres is on a 5Gi volume with no backup of any kind. Activity
data is append-mostly. Do this first, because it is the only step that is hard
to do later.

- Raise `postgres-storage` in `lib/db.libsonnet` from `5Gi` (Longhorn supports
  online expansion; verify on your storage class).
- Take a `pg_dump` of the `wisefood` database and confirm you can restore it.

Rough sizing: about 1 KB per recorded action. At 10,000 actions a day that is
~3.5 GB a year before retention trims it.

## 2. Apply the analytics schema by hand

Schema files only run under `entrypoint.sh init-db`, so on a live database this
is manual, as with every other `NN_*.sql` file here.

```bash
psql "$WISEFOOD_DB_URL" -v ON_ERROR_STOP=on -f wisefood-api/schemas/50_analytics.sql
psql "$WISEFOOD_DB_URL" -v ON_ERROR_STOP=on -f wisefood-api/schemas/51_analytics_rum.sql
```

`50` creates the `analytics` schema: six tables, twenty-six indexes. `51` adds
real user monitoring — the device a session ran on, browser errors and their
groups, click maps and page speed: five more tables, nineteen more indexes.
Every statement in both is `IF NOT EXISTS`, so re-running is safe; each has
been applied twice against a clean PostgreSQL 17.6 to confirm it.

Two of the RUM tables are high-volume and both ship switched **off**
(`capture.interactions`, `capture.vitals`), so applying the schema costs
nothing until somebody turns them on.

FoodScholar's new columns need nothing: `init_db()` runs its idempotent
`ALTER TABLE ... IF NOT EXISTS` set on every boot.

## 3. Build and push the images

Six images, all `make build push` in their repo. Every tag is `:latest`, so
Kubernetes pulls on restart — there is no tag to bump.

| Repo | Image | Why |
|---|---|---|
| `wisefood-api` | `wisefood/wisefood-api` | The recorder, ingest and report endpoints, the analytics schema, **and the retention script the CronJob runs** |
| `foodscholar` | `wisefood/foodscholar` | Review endpoints, telemetry, tracing switch |
| `foodchat` | `wisefood/foodchat` | Turn reporting, token accounting, tracing switch |
| `RecipeWrangler-Backend` | `wisefood/recipe-wrangler` | Search reporting on six surfaces |
| `wisefood-data-api` | `wisefood/data-catalog` | Catalog search reporting |
| `wisefood-ui` | `wisefood/wisefood-ui` | Insights console, footer session id, consent switch |

`core-components/keycloak-init` also changed. Rebuild
`wisefood/keycloak-init` too, or step 6 re-runs the old job and does nothing.

**Not an image:** `wisefood-client` is a PyPI package. FoodScholar and FoodChat
*do* depend on it — they embed its `Client` to read the catalog — but they pin
`wisefood==0.0.25`, so rebuilding them does not pull the new release. See
*Releasing the SDK*.

**Not rebuilt:** `platform-deployment` is applied, not built.

## 4. Deploy, in any order

`tk apply environments/wf-prod`.

**The UI needs an explicit restart.** Five services gained new environment
variables, so their manifests changed and `tk apply` rolls them. `lib/ui.libsonnet`
did not change, so the UI pod keeps running the old image until you say:

```bash
kubectl rollout restart deployment/wisefood-ui -n wf-prod
```

Order between services genuinely does not matter, and it is worth knowing why:

- **New services, old gateway** — services post to an endpoint that 404s, and
  the telemetry client switches itself off rather than retrying.
- **New gateway, old services** — the gateway records its own requests; service
  events simply do not arrive.

At this point `LOG_FORMAT=json` takes effect and every service starts stamping
the correlation id on its log lines. That is the one visible change from this
step, and it is the piece worth having even if you stop here.

## 5. Create the ingest secret

Add to the `secrets:` list in `wf-prod.yaml`, then re-run the secret step of
`wisefoodctl`:

```yaml
  - analytics-ingest-secret: "<32+ random characters>"
```

Every service references it with `optional: true`, so its absence closes the
service ingest endpoint rather than breaking a pod. Until it exists, the gateway
records what it can see itself and the services report nothing.

## 6. Turn on Keycloak event logging

Re-run the `keycloak-init` job. It sets `eventsEnabled`, `adminEventsEnabled`
and a 90-day expiry on the realm. Gives you logins and registrations, which no
application code can reconstruct after the fact.

## 6b. Throughput knobs (optional)

Defaults are sized for a platform serving thousands of events a second and need
no attention. They are environment variables on the gateway if you ever want
them:

| Variable | Default | What it decides |
|---|---|---|
| `ANALYTICS_QUEUE_MAX` | 50000 | Rows held in memory. About fifty seconds of buffer at 1,000/s — what makes a database hiccup invisible rather than lossy |
| `ANALYTICS_BATCH_MAX` | 1000 | Rows per INSERT |
| `ANALYTICS_WRITERS` | 4 | Batches written at once |

Measured on PostgreSQL 17.6: **~58,000 events/second accepted** on the request
path and **~16,000/second** sustained to the database at these defaults — 2.7×
what a single writer managed. Raising writers to 8 made it *worse*, so 4 is not
an arbitrary number.

The request path never waits for any of this. `record_event` is synchronous,
does no I/O, takes no lock, and enqueues with `put_nowait`; when the queue is
full it drops and counts rather than blocking. Analytics also has **its own
connection pool**, hard-capped with `max_overflow=0`, so a burst of page views
can never hold a connection a user's request is waiting for.

## 7. Enable collection

In `lib/pim.libsonnet`:

```jsonnet
observability: {
  ANALYTICS_ENABLED: true,
  ...
}
```

`tk apply` and restart the gateway. Recording starts.

## 8. Check it within five minutes

1. Open **Console → Analytics → Usage**. The "Needs attention" panel and the
   tiles should populate as traffic arrives.
2. Open **Console → Platform Operations** (admin). Under *Activity analytics &
   tracing*, `Recorded` should be climbing and `Dropped` and `Write errors`
   should both be zero. A non-zero `Dropped` means the recorder cannot keep up
   or cannot write — chase it, because losing data and having none look the same
   in every report.
3. Load any page as a normal user. A short reference like `k3f9-2xa7-lm4q`
   should appear in the footer.
4. Confirm a service is reporting: a recipe search should produce a row with a
   `recipewrangler` surface within a few seconds.

---

## Turning it off

Three levels, fastest first:

| Need | Action | Takes effect |
|---|---|---|
| Stop recording now | Platform Operations → *Recording activity* off | ~30 s, all replicas |
| Stop LLM tracing now | Platform Operations → *LLM tracing* off | ~30 s, all services. Prompt management keeps working |
| Stop click capture now | Platform Operations → *Interactions* off | ~30 s, and the browser stops gathering within 30 s too |
| Full rollback | `ANALYTICS_ENABLED: false`, `tk apply` | Next restart |

Click and page-speed capture are the only streams the **browser** does work
for, so they are the only ones where switching off matters to a visitor rather
than only to the database. The browser polls `/analytics/client-flags` every
30 seconds and installs or removes its listeners accordingly — turning them off
in the console stops the gathering, not just the recording.

Rolling the images back is also safe: the `analytics` schema is unreferenced by
the rest of the platform, so an older gateway simply ignores it. Nothing else
depends on these tables.

## Releasing the SDK

Separate from everything above, and optional. Release it when you want partners'
scripts and evaluation notebooks to start reporting — until then their usage
stays invisible in the reports, which is the status quo.

**Services do not use the SDK to report.** FoodScholar, FoodChat, RecipeWrangler
and the data catalog report through a vendored, stdlib-only `wf_telemetry.py`
that posts to the HMAC-signed internal endpoint. The SDK posts to the public
endpoint with a user's bearer token. Two callers, two trust levels, two
endpoints — a service reporting on behalf of a user whose token it never held
cannot use the path meant for that user's own browser.

FoodScholar and FoodChat *do* embed the SDK's `Client`, for reading the catalog.
That is the platform calling itself, so it must not be recorded as somebody's
activity: the client now refuses to report whenever it authenticates with client
credentials, and both call sites pass `telemetry=False` as well. FoodChat's
dependency was unpinned and is now `==0.0.25`, so a rebuild cannot silently pick
up a newer client.

```bash
cd wisefood-client
python -m build && twine upload dist/*
```

Already prepared: version bumped to **0.0.26**, changelog written, README
documents the opt-out. Telemetry is on by default for a first-party client
against its own platform, and off with `WISEFOOD_TELEMETRY=0` or
`Client(..., telemetry=False)`.

One fix worth knowing about: `__version__` was a literal that had drifted three
releases behind `pyproject.toml`, and it is what the client sends as `X-Client`.
Every SDK request would have been labelled `0.0.22`. It now reads from the
installed package, so it cannot drift again.

## Who may report, and how much

Every ingest endpoint requires a valid token — there is no anonymous path in.
A client is trusted to say *what happened to it* and never *who it is*:
identity comes from the token via the request context, so a browser cannot
file activity under someone else's name.

Volume is capped per identity, and this applies to **everyone**, not only to
guests. The platform's existing guest budget exempts anybody signed in, and a
signed-in account is not hard to obtain — which mattered here more than
elsewhere, because the cost of an event is not CPU but rows on the 5Gi volume
the whole platform shares. An unbounded authenticated caller was a
disk-exhaustion outage for every service.

| Guard | Value |
|---|---|
| Rows per minute, per identity | 6,000 (`ANALYTICS_INGEST_ROWS_PER_MINUTE`) |
| Burst after a quiet spell | 12,000 (`ANALYTICS_INGEST_BURST_ROWS`) |
| Rows in one request | 50 events / 25 errors / 200 interactions / 50 vitals |

Charged in rows rather than requests, because one request may carry two
hundred interactions or a single page view. Far above what a browser sends: it
buffers for five seconds and flushes what it has. Over the limit returns 429
with a retry hint, and the refusal does not charge the bucket — otherwise a
client that keeps hammering pushes its own recovery further away and never
gets back in.

The limiter is process-local, so across N replicas a caller gets up to N times
the limit. That is deliberate: a Redis counter would be exact but adds a
network round trip to the ingest path, and the existing Redis budget *fails
open* when Redis is down — precisely when a limiter is most needed. Approximate
and always present beats exact and sometimes absent, for a ceiling whose job is
to stop a volume filling.

`Rate limited` appears alongside `Dropped` in Platform Operations. They mean
different things: rate-limited is a client being stopped, dropped is the
platform failing to keep up.

## Errors: both halves

The console records what breaks in a **browser** and what throws on the
**server**, grouped the same way and listed together.

Server exceptions are hooked in two places, because either alone leaves a
class of failure invisible: `render()`'s handler catches nearly everything, and
the request middleware catches whatever escapes it. Each occurrence keeps its
stack, is attributed to the deepest frame in our own code (framework and
library frames are skipped), and is grouped by a fingerprint that survives
changing numbers in the message — so one fault is one group rather than one
group per user.

A resolved group that happens again reopens itself. Nobody has to notice.

**Expert verdicts now reach Langfuse.** Recording a review pushes it as an
annotation score on the trace that produced the answer, found by joining the
review's request id to the model call's trace id. The push happens after the
review is committed and a Langfuse outage only leaves the annotation missing,
never the review. It honours the tracing kill switch.

## What is recorded, and what is deliberately not

Worth knowing before this is switched on, because two of these are questions
somebody will ask:

- **The IP address is never stored.** Only a network prefix survives — IPv4
  truncated to /24, IPv6 to /48 — which is enough to spot one broken office
  network and not enough to identify a household. There is no setting that
  widens it.
- **The full user agent is kept only for a consenting user.** The parsed
  browser, OS and form factor are kept either way, because "12% of visits are
  iOS Safari" is about nobody.
- **Error messages and stack traces are redacted at the point of recording** —
  emails, bearer tokens, JWTs, long hex strings and query-string values are
  replaced before the row is written. They are then *kept* through consent
  stripping, deliberately: they describe the software, and removing them would
  leave an error report with no error in it for every non-consenting user,
  which under opt-in means every user.
- **No screenshots, no session replay, no keystrokes, no form values.** Click
  maps are a density grid over a route pattern, not a picture of anybody's
  screen.

## Two things that are not done

- **Secrets are still in git.** `wf-prod.yaml` and `langfuse/values.yaml` carry
  live production credentials. Adding the ingest secret puts one more there.
  Worth fixing before this deploy, not after.
- **`minikube.dev` does not evaluate**, for a pre-existing reason unrelated to
  this work: `lib/sysinit.libsonnet` references `images.API`, which that
  environment does not define.
