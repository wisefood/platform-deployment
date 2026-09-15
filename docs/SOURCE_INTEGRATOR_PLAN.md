# Source Integrator — a conversational agent for bringing new sources into the catalog

_Status: proposal. Companion to `LLM_SAFEGUARDING_AND_GATEWAY_PLAN.md`._

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

## 6. Decisions to make before building

1. **Model provider.** Native tool-calling is non-negotiable (the manual JSON
   loop is what the last attempt regretted). OpenAI is wired and keyed today;
   Claude needs a key provisioned. Recommendation: build on the
   OpenAI-compatible tool schema — which is also what APISIX `ai-proxy-multi`
   speaks — default to OpenAI now, add Claude as a second provider when its
   key exists, and route through the APISIX AI gateway so failover and
   per-consumer limits come for free (see the gateway plan, §1.3–1.5).
2. **Web search.** Provider-native (OpenAI / Claude built-in search) needs no
   new vendor or key and gives the "searches when it needs to" behaviour.
   A dedicated API (Brave, Tavily) gives more control and a cleaner data-egress
   story. Recommendation: provider-native behind the `web_search` tool, with
   the tool interface stable so a dedicated provider can replace it later.
3. **Playwright.** A real dependency (Chromium in the image). Start without it;
   `fetch_url` reports "needs a browser" for sites that refuse, and the
   expert can upload the PDF by hand. Add it when the backlog shows it is
   worth it.
4. **First content kind.** Guides — the pipeline exists, 125 sources wait,
   and national dietary guidance is the platform's core material.

## 7. Phases

**Phase 1 — foundation (no catalog writes yet).**
`wisefood-mcp` with read + research tools; proposal/run/tool-call tables
(`integrator_session`, `integrator_message`, `integration_proposal`,
`integration_run`, `integration_tool_call`) in FoodScholar's Postgres; the
agent loop with step/token budgets and a Langfuse trace per run; the seeded
backlog from the spreadsheet; the console page — chat, proposal cards with
approve/reject/rerank, the queue. Deliverable: an expert can ask "what
Bulgarian dietary guidance exists and may we use it?" and get ranked,
evidenced proposals they can approve — with approval landing nothing yet.

**Phase 2 — guides end to end.** Gated write tools for the guide path; the
run drives the existing extraction + import and reports job progress in the
same card style the console already has. Deliverable: approve → guide, its
artifact, its guideline entries, with full provenance.

**Phase 3 — articles.** DOI-first: Unpaywall/Crossref licence, article
creation, enrichment enqueue.

**Phase 4 — textbooks and FCTs.** The two extraction gaps.

**Phase 5 — recipes.** Generalised RecipeWrangler import + `license` on
`Source`.

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
