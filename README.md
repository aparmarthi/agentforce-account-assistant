# Nimbus Account Assistant

A production-shaped **Agentforce service agent** for a fictional connectivity provider ("Nimbus" — mobile, broadband, streaming), built with **Agent Script** and deployed to a Salesforce org. It handles four customer-service capabilities behind a single conversational router, and every capability is wired to the *right tool for the shape of the work*: deterministic Apex for computed reads, confirmation-gated Flows for writes, a grounded structured query for outage status, and a generative-guidance path that ends in a real support Case or a human handoff.

> **Design thesis:** one *probabilistic* router, four *deterministic* execution slices. The LLM decides **where** a conversation goes; it never computes balances, invents outage status, or writes records on its own. That separation is what makes the agent auditable.

**Status:** published `v4`, active. **API version:** 67.0. **Agent type:** `AgentforceServiceAgent`.

---

## Table of contents

- [Architecture at a glance](#architecture-at-a-glance)
- [The four capabilities](#the-four-capabilities)
- [Data model](#data-model)
- [Actions: Apex and Flows](#actions-apex-and-flows)
- [The router](#the-router)
- [Guardrails and safety](#guardrails-and-safety)
- [What is deliberately *not* used (Data Cloud, RAG)](#what-is-deliberately-not-used)
- [Repository layout](#repository-layout)
- [Setup and deploy](#setup-and-deploy)
- [Running the demo](#running-the-demo)
- [Lifecycle and versioning](#lifecycle-and-versioning)
- [Roadmap](#roadmap)

---

## Architecture at a glance

```
Customer
   │
   ▼
topic_selector  ── probabilistic router; routes on FULL conversation history; route-only (never answers directly)
   │
   ├─ billing         → apex://NimbusBillingAction              READ   · SOQL sum of unpaid invoices
   │
   ├─ plan_change     → flow://Nimbus_Preview_Plan_Change       READ   · resolve account + validate plan
   │                  → flow://Nimbus_Commit_Plan_Change        WRITE  · gated by preview-set variables
   │
   ├─ outage_status   → flow://Nimbus_Check_Outage              READ   · grounded lookup by region
   │
   ├─ troubleshoot    → (generative self-service guidance)
   │                  → flow://Nimbus_Create_Case               WRITE  · Case insert; full name required
   │                  → @utils.escalate                          HANDOFF· live human agent
   │
   └─ escalation · off_topic · ambiguous_question               guardrail subagents
```

The agent is one `AiAuthoringBundle` (`.agent` script + `bundle-meta.xml`). Everything else — Apex, Flows, custom objects, the permission set — is standard source-tracked Salesforce metadata under `force-app/`.

---

## The four capabilities

Each capability is a **subagent** in the Agent Script. A subagent owns an objective, its instructions, and the actions it may call.

### 1. Billing — deterministic read (Apex)

The customer asks for their balance or unpaid invoices. The subagent asks for a full name, then calls `NimbusBillingAction`, which queries the account and **sums the unpaid invoices in Apex**. The agent relays the returned figure verbatim — it is explicitly instructed never to compute, round, or paraphrase an amount. The number is correct by construction and auditable in the Apex.

### 2. Plan change — confirmation-gated write (two Flows)

Changing a plan is a two-step, human-in-the-loop write:

1. **Preview** (`Nimbus_Preview_Plan_Change`, read-only): resolves the account by name, validates that the requested plan exists and is **active**, and returns the plan's price and allowance. On success it **sets two mutable variables** (`plan_change_account_id`, `plan_change_plan_id`).
2. **Commit** (`Nimbus_Commit_Plan_Change`, write): only *available* when both gate variables are non-empty (`available when @variables.plan_change_account_id != ""`). It sets the account's `Current_Plan__c`.

The commit action literally cannot fire until a successful preview has populated the gate variables and the customer has explicitly confirmed. No preview, no write.

### 3. Service & outage status — grounded structured query (Flow)

The customer asks whether service is down in their area. The subagent asks for a region, then calls `Nimbus_Check_Outage`, which looks up the **active** outage record for that region and returns its status, summary, and estimated resolution. If no active outage exists, it returns `outageFound = false` and the agent says service is operating normally. The subagent is instructed to relay **only** what the Flow returns — it never invents status, cause, or timing. (See [why this is a structured query and not RAG](#what-is-deliberately-not-used).)

### 4. Troubleshoot → Case / escalate — generative guidance + write / handoff

The customer reports a technical problem with their own service or device. The subagent first offers **concrete self-service steps** (restart the router, check for a known outage, reinstall the app, etc.) — contained self-service is the preferred outcome. If that doesn't resolve it, the customer chooses:

- **Log a case** → `Nimbus_Create_Case` inserts a `Case` and returns the generated case number. The subagent **requires the customer's full name** before creating the case and never invents a case number.
- **Talk to a person** → `@utils.escalate` hands off to a live agent.

A subtle but important distinction is baked into the instructions: *asking to log a case does not trigger a human handoff* — those are two different outcomes.

---

## Data model

Four custom objects plus the standard `Case`. All data is **synthetic** — no real PII.

| Object | Key fields | Role |
|---|---|---|
| `Nimbus_Account__c` | `Customer_Name__c`, `Email__c`, `Tier__c`, `Current_Plan__c` (→ `Nimbus_Plan__c`) | The customer. Resolved by name. |
| `Nimbus_Invoice__c` | `Amount__c`, `Due_Date__c`, `Status__c`, `Nimbus_Account__c` (→ Account) | Billing lines; unpaid ones are summed. |
| `Nimbus_Plan__c` | `Monthly_Price__c`, `Data_Allowance__c`, `Is_Active__c` | Subscription catalog; only active plans are selectable. |
| `Nimbus_Outage__c` | `Region__c`, `Status__c`, `Summary__c`, `Estimated_Resolution__c`, `Is_Active__c` | Outage records, keyed by region. |
| `Case` (standard) | `SuppliedName`, `Subject`, `Description`, `Origin`, `Status`, `Priority` | Troubleshoot handoff target. |

Seed data lives in `data/` (10 accounts, their invoices, 5 plans incl. one retired, 4 outage records across Northeast / Bay Area / London / Midwest).

---

## Actions: Apex and Flows

### Apex — `NimbusBillingAction`

`with sharing`, exposed via `@InvocableMethod`. Takes a customer name; returns `found`, a human-readable `summary`, `outstandingBalance`, and `openInvoiceCount`. It queries `Nimbus_Account__c` by exact name (handling the not-found and multiple-match cases), then queries unpaid `Nimbus_Invoice__c` and sums `Amount__c`. Covered by `NimbusBillingActionTest`.

### Flows — all `AutoLaunchedFlow`, `SystemModeWithoutSharing`

| Flow | Type | What it does |
|---|---|---|
| `Nimbus_Preview_Plan_Change` | read-only | Looks up account by name and active plan by name; returns resolved IDs + price + allowance. Decisions branch on "found?". |
| `Nimbus_Commit_Plan_Change` | write | `recordUpdates` sets `Current_Plan__c` on the account to the previewed plan ID; returns `success` + `newPlanName`. |
| `Nimbus_Check_Outage` | read-only | Looks up the active outage for a region; returns status/summary/estimated resolution, or `outageFound = false`. |
| `Nimbus_Create_Case` | write | Assigns Case fields, `recordCreates` inserts the Case, then re-queries to return the generated `CaseNumber`. |

The read/write split is intentional: previews and lookups never mutate; the two write Flows are the only components that change org state, and each is fronted by an explicit gate (confirmation for plan change, required name for case).

---

## The router

`start_agent topic_selector` is the entry point. It is authored as a **router only** — its instructions forbid it from answering the customer, asking for details, or claiming it has done anything. On every turn it emits exactly one `@utils.transition` to one of seven subagents.

Two hard-won behaviors are encoded in its instructions:

- **Route on full history, not just the last message.** If a customer said "I want to change my plan" and then sends only their name, that later message is still a plan change — the router must not re-interpret it as a fresh, ambiguous request.
- **Keep case-logging inside `troubleshoot`.** When a customer in an active troubleshooting conversation says "log a case," the router keeps them in `troubleshoot` (which owns case creation) rather than sending them to the `escalation` subagent. Explicit "talk to a human" requests *outside* an active troubleshoot flow go to `escalation`.

---

## Guardrails and safety

- **No LLM-computed money or status.** Balances come from Apex; outage details come from a Flow. The agent relays returned values verbatim.
- **Human-in-the-loop writes.** Plan changes require a preview + explicit confirmation; cases require the customer's name.
- **Prompt-injection resistance.** The system instructions and the `off_topic` / `ambiguous_question` subagents instruct the agent to disregard attempts to override rules, reveal system/configuration details, or expose available functions.
- **Least-privilege access.** The `Nimbus_Assistant_Access` permission set grants only what the agent needs: `NimbusBillingAction` class access, object permissions (create/read/edit on `Case`; read on the custom objects it uses), field permissions, and flow access for the four Flows. `Case` is granted create/read/edit but **not** delete/modify-all.

---

## What is deliberately *not* used

This is a design decision worth calling out explicitly, because reaching for heavier machinery than the data warrants is a common anti-pattern.

| Capability | Used? | Why |
|---|---|---|
| **Data Cloud** | No | Not provisioned in the target org, and no capability here needs it. |
| **Data Library / ADL indexing** | No | There is no document corpus to index. |
| **RAG / vector retrieval** | **No — on purpose** | Every piece of grounded data (outages, plans, invoices) is **structured and keyed** (outages by region, plans by name, invoices by account). A deterministic query is the correct, auditable, zero-hallucination tool. RAG over structured data would add latency and a hallucination surface for no benefit. |
| **Prompt Template action** | No | Generative troubleshooting guidance comes from the `troubleshoot` subagent's own reasoning; no separate template is needed at this scope. |

**When RAG *would* earn its place:** if troubleshooting guidance moves from the model's general knowledge to a real Nimbus knowledge base of **unstructured** articles, a Data Library + retrieval becomes the right tool. That is scoped as roadmap, not shoehorned in now.

---

## Repository layout

```
force-app/main/default/
├── aiAuthoringBundles/Nimbus_Account_Assistant/   # the Agent Script (.agent) + bundle-meta
├── classes/                                        # NimbusBillingAction (+ test)
├── flows/                                          # the four AutoLaunched Flows
├── objects/                                        # Nimbus_Account__c / Invoice / Plan / Outage
├── permissionsets/Nimbus_Assistant_Access...       # least-privilege access for the agent user
├── bots/                                           # published runtime (bot + version metadata)
└── genAiPlannerBundles/                            # published planner bundles, one dir per version

data/            # synthetic seed records (accounts, invoices, plans, outages) + import plan
agent/           # the Agent Spec (design doc)
docs/            # demo-script.html (live demo walkthrough + architecture glance)
manifest/        # package.xml (full component manifest)
```

---

## Setup and deploy

Requires the Salesforce CLI (`sf`), an org with Agentforce enabled (API v66.0+), and an Einstein Agent User.

```bash
# 1. Authenticate and target an org
sf org login web --alias sdo
sf config set target-org sdo

# 2. Deploy all metadata from the manifest
sf project deploy start --manifest manifest/package.xml

# 3. Assign the permission set to the running/agent user
sf org assign permset --name Nimbus_Assistant_Access

# 4. Load synthetic seed data
#    accounts + invoices come via the import plan (preserves the account→invoice relationship):
sf data import tree --plan data/nimbus-seed-plan.json
#    plans and outages load directly:
sf data import tree --files data/Nimbus_Plan__c.json
sf data import tree --files data/Nimbus_Outage__c.json
```

The agent bundle is already published and active in the source org. To iterate on the draft locally and preview without publishing:

```bash
sf agent preview start --use-live-actions --authoring-bundle Nimbus_Account_Assistant
```

To validate the Agent Script compiles:

```bash
sf agent validate authoring-bundle --api-name Nimbus_Account_Assistant
```

---

## Running the demo

The best surface is **Agent Builder → Conversation Preview** against the active `v4`, with the reasoning/plan panel enabled so you can point at *which subagent handled the turn and which action fired* — proof the actions actually run, not just plausible text.

**No context variables need to be set.** The four linked `MessagingSession` variables auto-bind in a live channel and stay empty in preview (nothing reads them); the two plan-change gate variables are set internally by the preview action. The agent resolves the customer by name at conversation time, so it demos cleanly anywhere.

A full walkthrough — utterances grounded in the seed data, expected responses, negative tests, and what to watch in each trace — is in [`docs/demo-script.html`](docs/demo-script.html) (open in a browser; print to PDF for a leave-behind).

Quick smoke test (CLI):

```bash
sf agent preview start --api-name Nimbus_Account_Assistant
# then, e.g.:  "What's my balance?" → "Ava Thompson"   (billing)
#              "Switch me to Premium, I'm Ava Thompson" (plan change, confirm to commit)
#              "Is there an outage in the Northeast?"   (outage status)
#              "My streaming keeps buffering" → "log a case" → name  (troubleshoot → Case)
```

---

## Lifecycle and versioning

The agent was built one vertical slice at a time — billing, then plan change, then outage status, then troubleshoot — each validated with live-action previews before release. Each release is an irreversible **publish + activate** that creates a permanent version; the runtime metadata for every version (`v1`–`v4`) is captured in `bots/` and `genAiPlannerBundles/` and committed, so the source tree mirrors what's live in the org. `manifest/package.xml` lists all four planner-bundle versions.

---

## Roadmap

- **Evals harness** — automated regression tests over routing accuracy, action invocation, guardrail enforcement, and prompt-injection resistance (the `evals/` directory is scaffolded for this).
- **Knowledge-grounded troubleshooting** — replace model-general troubleshooting advice with retrieval over a real Nimbus knowledge base; this is the one capability where a Data Library + RAG is the right tool.
- **Live messaging channel** — deploy through Messaging for Web to exercise the linked `MessagingSession` context variables end-to-end.

---

*Synthetic data only — no real customers, PII, or credentials. Built as a hands-on Agentforce / Agent Script reference implementation.*
