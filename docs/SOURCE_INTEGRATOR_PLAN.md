# Source Integrator — a conversational agent for bringing new sources into the catalog

_Status: **Phases 1–2 built** (2026-09-16). Companion to `LLM_SAFEGUARDING_AND_GATEWAY_PLAN.md`._

> **What exists now.** `wisefood-mcp` (13 tools, 39 tests) in wisefood-client;
> `src/integrator/` in FoodScholar with four tables, the agent loop and the
> approval wall (20 tests against a real Postgres); admin/expert-gated proxy
> routes on the gateway; `/console/integrator` in the UI. Catalog writes are
> **off** — the write tools are built and gated shut, and are not even shown
> to the model. See §7 for what each phase still owes.

The expert console gains an assistant that researches candidate sources, ranks
them, checks whether their licence permits use, and — only after a person
approves — integrates them into the data catalog with full provenance,
routing each through the extraction pipeline for its kind (dietary guide,
article, textbook, recipe collection, food-composition table). The
interaction is a conversation that keeps its context; the assistant can search
the web on its own initiative or on request; nothing reaches the catalog
without a human clicking approve.

## 0. What is actually there (verified against the code, 2026-09-15)

**A backlog already exists.** `wisefood-client/Sources_Catalogue (1).ods` holds
**219 candidate sources** across five sheets that map one-to-one onto the
catalog's entity types:

| sheet | rows | catalog entity |
|---|---|---|
| National_Dietary_Guides | 125 | `guides` → `guidelines` |
| Nutrition_Journals | 61 | `articles` |
| Food_Composition_Tables | 23 | `fctables` |
| Textbooks | 6 | `textbooks` → `textbook_passages` |
| Recipe_Collections | 4 | `rcollections` → RecipeWrangler |

Columns: Country, Title, Population Group, Type (pdf/html), Language, Pages,
URL. This is the integrator's starting queue, not a blank prompt.

**The catalog already models what the integrator must fill.**
`wisefood-data-api` writes via `POST/PUT /{entity}/{urn}`; files via
`POST /artifacts/upload` with `parent_urn`. `license: LicenseId` is a
first-class enum on guides, textbooks and collections (`CC-BY-4.0`, `CC0`,
`public-domain`, `Proprietary`, `unspecified-oa`, …); `doi` and `publisher`
on textbooks. Guideline entries carry page-level references into the parent
guide's artifact. So provenance and licence are fields to *populate*, not a
schema to invent.

**The PDF decomposition pipeline exists — for guides.** FoodScholar:
`POST /guidelines/extract/{artifact_uuid}` enqueues (Redis: `rpush`, locks,
`QUEUED → RUNNING → SUCCEEDED | FAILED`), PyMuPDF reads the file,
`GET …/extract/{artifact_uuid}` polls, `POST /guidelines/import/{artifact_uuid}`
lands entries in the catalog. Article enrichment uses the same Redis job
pattern (`enrichment_jobs.py`), and the console already renders it
(`EnrichmentWorkerCard.vue`, `foodscholarEnrichmentApi.ts`: enqueue, poll,
pause, restart). Textbook→passage and FCT ingestion from a PDF: **no pipeline
found**. Recipes: onboarding is one hand-written `scripts/import_<source>.py`
per source in RecipeWrangler (scrape → Groq profiling chain → Neo4j →
Postgres → ES); the `Source` registry has curated/trusted/provenance flags
but **no licence field**.

**`wisefood-mcp` is promised and absent.** `wisefood-client/docs/integrations/ai-agents.md`
documents a companion MCP server (`wisefood-mcp`, env-configured, exposes the
clients as tools). There is no entry point in `pyproject.toml`, no module, no
sibling repo. `wisefood-client` does have typed `create` on guides, textbooks,
articles (via `base.py`) and `artifacts.upload` — the right foundation for it.
The `mcp` SDK (2.2.0) is installable and not installed anywhere.

**Agent substrate.** Providers wired: Groq (`llama-3.1-8b-instant` et al.) and
OpenAI (key `openai-key` in prod secrets). **No Anthropic key in prod.**
Tool use in the services is `with_structured_output` only; there is no native
tool-calling agent loop. `foodscholar-lib`'s one agentic experiment drove a
manual `{action, args}` JSON protocol and its own plan names "no native
tool-calling" as the constraint it worked around. **No web search or crawl**
exists in any service; `scripts/scrape_safefood_recipes.py` used Playwright
because the site sat behind a Cloudflare challenge. Langfuse traces every LLM
call; the APISIX `ai-proxy-multi` route fronts Groq/OpenAI (see the gateway
plan). FoodChat persists conversations (`SessionRow`/`MessageRow`, a
`SessionTitler`) — the right *pattern* for the integrator's memory, but the
wrong *tenancy* (household members, not experts).

## 1. Shape

```
 expert console (Nuxt)                        FoodScholar: src/integrator/
 ┌────────────────────────────┐               ┌──────────────────────────────┐
 │ /console/integrator        │  gateway      │ conversation loop            │
 │  chat · proposals · queue  │◀────────────▶│  (native tool-calling)        │
 │  approve / rerank / reject │  /integrator  │  step + token budget         │
 └────────────────────────────┘               │  Langfuse trace per run      │
                                              └──────────────┬───────────────┘
                                                             │ tool calls
                                              ┌──────────────▼───────────────┐
                                              │ wisefood-mcp (new package)   │
                                              │  read: search/get catalog    │
                                              │  research: web_search,       │
                                              │            fetch_url,        │
                                              │            licence_evidence  │
                                              │  write: create_*, upload,    │
                                              │         enqueue_extraction   │
                                              │   ▲ every write requires an  │
                                              │   │ APPROVED proposal id     │
                                              └───┼──────────────────────────┘
                                                  │ wisefood-client
                                   ┌──────────────┴─────────────┐
                                   │ data catalog · FoodScholar │
                                   │ pipelines · RecipeWrangler │
                                   └────────────────────────────┘
```

**Where the agent lives.** In FoodScholar as its own package
(`src/integrator/`), exposed through the gateway like every other surface.
FoodScholar already has the Redis job orchestration, PyMuPDF, the LLM and
Langfuse clients, and two of the extraction pipelines in-process; a new
service would duplicate all of that plumbing and then call FoodScholar over
HTTP anyway. The package boundary keeps it extractable later.

**But it acts through the tool layer, never directly.** The agent writes to
the catalog only by calling `wisefood-mcp` tools, which call `wisefood-client`,
which call the gateway. This is not ceremony: it is what makes provenance and
approval *structural*. Every write is a recorded tool call with a proposal id,
and the tool refuses to run without one in the approved state. An external
MCP client (Claude Desktop, an IDE) gets the identical surface, which is what
the docs already promise.

**The provider executes exactly one thing: web search.** This is a rule, not
a preference. No catalog, research, proposal or write tool is ever defined
as a provider-hosted tool or run on the provider's side. All of them live in
`wisefood-mcp`, are executed by our own agent loop, and are recorded by us.
The model's part is to *choose* a tool and its arguments; ours is to run it,
check it, and write it down. The one exception is web search, which Groq runs
inside its Compound systems because that is the only place it exists — and
even that is wrapped as an MCP tool of ours (`research`), so from the
integrator's side it is indistinguishable from the rest and appears in the
audit like the rest. Portability follows for free: swapping the provider
changes one adapter and nothing about the tools.

## 2. The three guarantees

These are enforced in the tool layer and the state machine — not in the
prompt. A prompt is advice; these are walls.

### 2.1 Nothing lands without a person

An `integration_proposal` moves through
`researching → proposed → approved → running → imported | rejected | failed`.
The conversation can draft everything: find sources, read them, propose a
licence, propose a target entity, draft its metadata, plan the pipeline
steps. Every write tool (`create_guide`, `upload_artifact`,
`enqueue_extraction`, `import_guidelines`, …) takes a `proposal_id` and fails
unless that proposal is `approved` — and approval is a console click by an
`admin`/`expert`, recorded with `sub` and timestamp. The model cannot approve
its own proposal because there is no tool for it.

### 2.2 Licence is evidence, proposed, confirmed — never decided

The assistant gathers evidence — licence statements on the page or in the
PDF, `rel="license"` links, CC badges, publisher OA policy, for DOIs the
Unpaywall/Crossref licence record, the site's terms — and proposes a value
**from the catalog's existing `LicenseId` enum** with a confidence and the
quoted evidence. The expert confirms or corrects it; the confirmed value is
what gets written, alongside the evidence.

Hard rules in the tool layer:

- A proposal with no determinable licence is `unspecified` and **cannot be
  approved** without an expert override that records a reason.
- `Proprietary` (or any non-permissive value) blocks ingestion of the *content*;
  metadata-only registration (title, URL, publisher — a pointer, not a copy)
  stays allowed, and the proposal says which it is doing.
- The licence and its evidence are stored on the entity and on the proposal.
  A later challenge can be answered from the record, not from memory.

### 2.3 Provenance is a chain, not a note

For every integrated entity: the original file as an `artifact` with
`parent_urn`; `source_url`; the `integration_run` id; the proposal id; who
approved and when; the licence and its evidence; the pipeline steps and their
job ids; and a pointer to the conversation transcript. Where the entity has a
dedicated field (`url`, `license`, `doi`, `publisher`, `organization_urn`) it
is used; the rest goes into `extras.integration` so it travels with the
entity through the existing API and client. Guideline entries keep the
page-level artifact references the extractor already produces.

## 3. Tool surface (`wisefood-mcp`)

One server, three groups. Read and research tools are always available;
write tools are gated as in §2.1.

| group | tool | notes |
|---|---|---|
| read | `search_catalog(kind, q)` · `get_entity(urn)` · `list_organizations()` · `catalog_coverage(kind, country?, population?)` | coverage answers "do we already have Bulgaria's adult guide?" — the ranking needs it |
| read | `backlog_list(kind?, status?)` · `backlog_get(id)` | the 219 seeded rows, plus anything the assistant or an expert adds |
| research | `web_search(q, n)` | provider-native by default (see §6); pluggable to Brave/Tavily |
| research | `fetch_url(url)` → readable text, metadata, content-type; PDFs are stored as a *pending* artifact and return page count + first-page text | httpx + readability first; Playwright only behind a flag, for sites that need it |
| research | `licence_evidence(url \| doi)` | scans page/PDF/robots/terms; for DOIs queries Unpaywall and Crossref; returns quotes + a proposed `LicenseId` + confidence |
| research | `classify_source(url)` | which entity kind, language, country, population group — a proposal, editable |
| propose | `create_proposal(...)` · `update_proposal(...)` · `rank_proposals(criteria)` | proposals are the unit of approval; ranking writes scores + rationale, re-rankable by the expert |
| write (gated) | `create_guide/article/textbook/rcollection/fctable(proposal_id, spec)` · `upload_artifact(proposal_id, parent_urn, pending_artifact)` · `enqueue_guideline_extraction(proposal_id, artifact_uuid)` · `import_guidelines(proposal_id, artifact_uuid)` · `enqueue_article_enrichment(proposal_id, urn)` · `register_recipe_source(proposal_id, …)` | each records a tool-call row with inputs, outputs and job ids |

The server is a small package (`wisefood-mcp`, `mcp` SDK, `wisefood-client`
underneath) with a `wisefood-mcp` console entry point exactly as documented.
FoodScholar's agent imports it as a library; external clients run it as a
process. One implementation, two transports.

## 4. Ranking

Explicit rubric, stored with the proposal, editable by the expert — not a
hidden prompt. Signals:

- **licence permissiveness** (the largest weight; a blocked licence ranks last)
- **authority** (national body, WHO/EFSA, university press, peer-reviewed)
- **coverage gap** — country × population group × language not yet in the
  catalog, weighted toward the pilot countries (GR, IE, HU, SI from the
  existing sources)
- **tractability** — HTML or clean PDF vs scanned/paywalled/Cloudflare
- **recency** and **size**

The assistant scores and explains; the console shows the list and lets the
expert drag to rerank. Reranks are stored as `expert_rank` beside
`proposed_rank`, and the rubric weights can be nudged from the console —
which is how the ranking learns without anyone training anything.

## 5. Per-kind pipelines — what exists and what does not

| kind | path | state |
|---|---|---|
| dietary guide (PDF/HTML) | `create_guide` → `upload_artifact` → `enqueue_guideline_extraction` → poll → `import_guidelines` | **exists end to end.** 125 in the backlog. First target. |
| article (DOI/URL) | `licence_evidence(doi)` → `create_article` → `enqueue_article_enrichment` | **exists**; Unpaywall gives the licence per DOI, which makes journals the cleanest licence story of the five |
| textbook (PDF) | `create_textbook` → `upload_artifact` → *passage extraction* | **gap:** no PDF→passages pipeline found; PyMuPDF + the guideline extractor's chunking is the obvious base |
| food-composition table | `create_fctable` → *table extraction* | **gap:** no pipeline; tables in PDF/XLS need their own extractor |
| recipe collection | `create_rcollection` + `register_recipe_source` → RecipeWrangler import | **largest gap:** today one bespoke script per source. Needs a generalised import in RecipeWrangler (URL list or feed → parse → profiling chain), and a `license` field on `Source` |

## 6. Decisions — taken 2026-09-15, and the one constraint they create

**Provider: Groq only.** No new vendor, no new key. Every model Groq hosts
supports user-defined tool calling; for the agent loop the recommended
choices with parallel tool calls are `llama-3.3-70b-versatile` and the
`openai/gpt-oss-120b` / `openai/gpt-oss-20b` pair — the latter two are
already what FoodChat and FoodScholar run on Groq today (they are the model
names in the console's LLM observability charts), so tracing, pricing and
the APISIX `ai-proxy-multi` route already know them. Start the loop on
`openai/gpt-oss-120b`; keep the model id a setting so it can be swapped from
the console without a deploy, as the gateway plan already allows.

**Web search: provider-native.** Groq provides this through its Compound
systems — `groq/compound` (several tool calls per request) and
`groq/compound-mini` (one, ~3× lower latency) — with built-in web search,
visit-website, code execution and Wolfram Alpha, and the system decides on
its own when to search. That is exactly the "searches implicitly like
ChatGPT" behaviour asked for.

**The constraint.** Groq's docs are explicit: on `groq/compound*`,
*"custom user-provided tools are not supported."* One model therefore cannot
both search the web natively and call the catalog tools. The design splits
into two roles, which turns out to be the cleaner architecture anyway:

| role | model | tools | what it does |
|---|---|---|---|
| **researcher** | `groq/compound` | Groq built-ins only (search, visit, code) | given a question or a backlog row, finds candidates, reads them, returns structured findings with the URLs it visited and the text it saw |
| **integrator** | `openai/gpt-oss-120b` (tool-calling) | `wisefood-mcp` tools | runs the conversation, calls the researcher as *one of its tools*, checks coverage against the catalog, proposes licences from the researcher's evidence, drafts proposals, drives the gated writes |

The researcher is wrapped as an MCP tool (`research(query \| url) → findings`)
so the integrator never knows or cares which model did the searching, and so
the console's audit shows research as a tool call like any other — with the
URLs visited recorded, which §2.3 needs. If Compound's search ever proves too
shallow for a class of source, a Brave/Tavily `web_search` tool drops in
behind the same interface with no change to the integrator.

Two notes for the deployment: Compound is not available on Groq's
regional/sovereign endpoints, so the researcher must use the global endpoint;
and Groq excludes Compound from HIPAA-covered processing, which does not
apply here — this is source research by experts, with no member data in the
loop — but is the kind of thing worth stating once.

**Playwright: deferred.** `fetch_url` reports "needs a browser" for sites
that refuse plain HTTP; the expert can upload the PDF by hand; add Chromium
to the image only when the backlog shows it earning its weight.

**First content kind: guides.** The pipeline exists and 125 sources wait.

**One reading to confirm during review.** "We don't implement tools via the
provider, only the web search" is taken above to mean *no provider-hosted or
provider-executed tools except search* — the model still selects our tools
through its function-calling interface, and we execute them. If it is meant
more strictly — that the model must not use function-calling at all, and
should pick tools by emitting structured JSON that our loop dispatches — that
is also buildable, but it is the manual action protocol the earlier
`foodscholar-lib` agent used and its own plan regretted (brittle argument
parsing, no parallel calls, every model upgrade re-tuned by hand). Say which,
and §1 and this section will be adjusted before anything is built.

**Next step: review.** Nothing is built until this document has been read
and the scope or phasing adjusted.

## 7. Phases

**Phase 1 — foundation. ✅ Built 2026-09-15.**

| piece | where |
|---|---|
| Tool layer, 13 tools, 3 groups | `wisefood-client/src/wisefood_mcp/` |
| MCP server process (`wisefood-mcp`) | `wisefood_mcp/server.py`, `pip install wisefood[mcp]` |
| Tables: session, message, proposal, tool call, backlog | `foodscholar/src/models/db.py` |
| Agent loop, budgets, replay | `foodscholar/src/integrator/agent.py` |
| Approval wall (not a tool) | `foodscholar/src/integrator/service.py::approve` |
| API, admin/expert gated | `wisefood-api/src/routers/foodscholar.py` |
| Console page | `wisefood-ui/app/pages/console/integrator.vue` |
| Backlog seeder | `foodscholar/scripts/seed_integrator_backlog.py` |

Notes worth carrying forward:

* The seeder imports **217** of the spreadsheet's 219 rows and names the two
  it skips (country-only rows with nothing else). The food-composition sheet
  has no Title column at all, so a title is built from the country.
* `wisefood_mcp` is importable **without** the `mcp` SDK. That matters: the
  SDK needs `starlette>=1.0` and FastAPI 0.115 needs `<0.47`, so the two
  cannot share an environment. FoodScholar depends on plain
  `wisefood>=0.0.27`; only the standalone server process takes the `[mcp]`
  extra.
* **Transparency** is the part that turned out to matter most. Every turn
  produces a timeline — what it searched for, which pages it opened, what the
  licence evidence said, how long each took — in the same shape FoodScholar's
  Q&A already streams, so the console renders both with one component. What
  was *attempted* and what *came of it* are separate fields: the first
  version overwrote the query with the error, and a failed search that has
  lost its query cannot be judged. The prompt states plainly that the
  assistant cannot approve anything or write to the catalog itself.
* **Ranking** is arithmetic over established facts, not a number the model
  produced: licence (heaviest), coverage gap, authority, tractability,
  completeness — each named, weighted and stored on the proposal, with
  weights tunable from settings. An undetermined licence scores 0.3 rather
  than 0, or a fresh backlog would bury itself.
* **Tracing**: one Langfuse trace per turn with a child span per tool call,
  inert when tracing is off, every backend failure swallowed.
* Still open after Phase 1: nothing has run against a live Groq key — the
  `research` tool is verified against a faithful fake of Compound's
  `executed_tools` shape, not the real thing. And the console has no page for
  editing the rubric's weights; they are settings, changed by an operator.

**Phase 2 — guides end to end. ✅ Built 2026-09-16.**

* **The executor, not the model.** Phase 1 planned to "show the write tools to
  the model and let it drive". Building it showed that to be wrong on three
  counts, and it was changed: an extraction over a 90-page PDF runs for
  minutes, which no conversational turn survives; a run that fails halfway has
  to resume from the step that failed, which is a state machine rather than a
  prompt; and what gets written into a public-health catalog should not vary
  with a sampling temperature. So `integrator/executor.py` runs a fixed
  sequence per kind — and runs it *through the same gated tools*, so every
  step still passes `require_approved` and still lands in the audit table
  exactly as a model-issued call would. The write tools stay hidden from the
  chat model.
* **The pipeline**, for a guide: `create_guide` → `upload_artifact` →
  `enqueue_guideline_extraction` → poll `guideline_extraction_status` →
  `import_guidelines` as a preview → `import_guidelines` for real. Articles
  and textbooks get the first two steps; there is no extraction behind them.
* **Preflight refuses before writing.** A guide with no fetched PDF, an
  unapproved proposal, a kind with no pipeline, writes switched off — all
  caught before anything is created, because a half-created guide is somebody
  having to notice and delete it. A licence that forbids copying registers the
  reference and stops, which is the `content_permitted` rule made visible.
* **`integration_runs`**, a row per *attempt*. Folding the state onto the
  proposal would mean a retry erased the evidence of why the first try failed.
  A retry reuses the urn and artifact the failed attempt created rather than
  making a second copy of either.
* **Stalled, computed not stored.** A run whose pod died mid-extraction is
  indistinguishable from a working one by its status column, and one of them
  needs a person. A heartbeat older than five minutes reads `stalled` to every
  reader, without writing the column back — the worker may yet return — and a
  stalled run does not block a retry.
* **Two bugs in the Phase 1 write tools**, found by building on them and both
  silent: `import_guidelines` posted `guide_urn` where
  `GuidelineImportRequest` requires `guide_id`, which validates as a *missing*
  field — a 422 and no import; and the planned count of a dry run is not
  `total_created` (which is 0 by definition on a preview, since nothing was
  created) but the number of items marked `would_create`. Reading the former
  would have failed every run with "nothing new to import".
* **The console**: `RunPanel.vue` on the approved card, polling every five
  seconds with a chained timeout, showing the stage, the page counter while a
  document is being read, what landed, and a retry on failure. Preview and
  Integrate are separate presses.
* **Where it lives**: the Source Integrator is a section of the **Asset
  Manager** (`/console/assets/integrator`), not a category of its own. The
  other four asset sections are libraries of what it brought in.
* Still open: `INTEGRATOR_WRITES_ENABLED` stays **off** by default, including
  now that this works — a deployment should turn writes on when somebody is
  there to watch the first one, not because it pulled a new image. And nothing
  has still run against a live Groq key.

**Security pass — 2026-09-16.** An audit of the whole surface, after the
question "can a user drive this freely, or flood us, and does the agent reflect
the caller's rights?". Four findings, all now closed.

* **`fetch_url` was an SSRF.** It validated the scheme and nothing else, and
  followed redirects blindly. `http://169.254.169.254/…`, `http://redis:6379`
  and the gateway's own internal port were all reachable from the pod, and the
  body came back into the model's context. It is also the worst place for it:
  the tool takes a URL the *model* chose, and the model chose it from pages
  `research` returned, so the destination is attacker-influenced input — a
  page can say "see the full text at …" and pick the target. Now every
  hostname is resolved and every address it resolves to must be public, one
  inward answer is enough to refuse, each redirect hop is re-checked, and the
  size cap bites while streaming instead of after the body is buffered.
  `WISEFOOD_MCP_ALLOWED_PRIVATE_HOSTS` is a list of names rather than a
  switch, so allowing an internal mirror does not also open the metadata
  service. Residual risk, stated rather than papered over: the connection is
  made by hostname afterwards, so DNS rebinding is mitigated, not closed.
* **The agent acted as a service account.** It built its catalog client from
  `WISEFOOD_CLIENT_ID/SECRET`, so an expert who may not edit guides could edit
  one by asking the assistant to. The gateway now forwards the caller's own
  bearer in `X-WiseFood-Delegated-Token` — a header, because bodies are logged
  and this one is persisted to an audit table — and the client acts with their
  roles. `wisefood-client` 0.0.29 adds `Credentials(access_token=…)` for it,
  and the property that makes it worth anything is negative: a delegated
  client **cannot** obtain a token by itself. `authenticate()` raises, an
  expired token raises, and there is no fallback. Without a token the catalog
  tools are simply absent from the turn, because a failure that makes the
  agent *more* capable is the kind nobody reports.
* **Nothing was rate limited.** Now 60 turns per person per hour, 3 concurrent
  runs per person and 10 across the deployment — the last bounding threads as
  much as spend, since each run holds one for as long as its extraction takes.
  Counted from Postgres rather than a cache, so an outage cannot quietly lift
  the limit, and stalled runs are discounted or a node failure would consume
  capacity permanently. Both surface as 429 with `Retry-After`.
* **The audit trail was readable by every expert.** A tool call carries the
  queries a curator typed and the URLs they were chasing. An expert now sees
  their own; an admin sees everything, because an audit trail nobody can read
  in full is not one. The proposal queue stays shared — curators rank each
  other's candidates, which is its purpose.

Unchanged and still true: every integrator route is admin-or-expert at the
gateway; `user_sub` comes from the token and never from the body; sessions are
ownership-checked; and no tool approves. The standalone `wisefood-mcp` process
is a different trust model and says so in its own docstring — it acts with
whatever credentials its environment holds, for whoever can reach its pipe, and
is meant to be run as a local operator tool rather than a shared service.

**Phase 3 — articles.** DOI-first: Unpaywall/Crossref licence (already in
`licence_evidence`), article creation, enrichment enqueue.

**Phase 4 — textbooks and FCTs.** The two extraction gaps in §5.

**Phase 5 — recipes.** Generalised RecipeWrangler import and a `license`
field on `Source`.

## 8. Risks, named

- **Data egress.** Research queries and fetched page text go to the model
  provider. No user PII is involved — this is source research by experts —
  but it should be stated in the deployment notes and kept off the FoodChat
  data path.
- **Licence misclassification.** Mitigated structurally (§2.2): proposed with
  evidence, confirmed by a person, blocked when unknown, recorded forever.
- **Scraping and terms.** `fetch_url` honours robots.txt and identifies
  itself; Playwright is opt-in; a site that refuses is reported, not
  circumvented.
- **Runaway runs.** Hard step and token budgets per run; a run that exceeds
  them stops and says so; Langfuse cost per run is visible in the console.
- **Scope creep.** Five kinds, three with missing pipelines. The phases
  exist so that Phase 2 ships value on the material the platform is actually
  about before anything is generalised.
