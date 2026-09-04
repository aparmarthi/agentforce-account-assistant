# Nimbus Connected Account Assistant — Design Spec

**Date:** 2026-09-02
**Author:** Amey Parmarthi
**Purpose:** A working, version-controlled Agentforce agent that can be *demoed live* and *explained as a solution design*. Deliberately domain-neutral so the capabilities generalize across industries.
**Target org:** SDO (Simple Demo Org), alias `sdo` — preloaded with Agentforce Sales/Service, Data 360, Platform licenses.
**Build path:** ADLC toolchain (CLI-deployed via `sf`), version-controlled in this repo.

---

## 1. Problem Statement (AI PM lens)

**Problem:** Subscription/service orgs field high volumes of repetitive account inquiries — billing questions, plan changes, outage/service status, and troubleshooting. Human agents are expensive and slow for tier-1 work; customers wait; simple issues consume senior capacity.

**Who:** Customers of a fictional connectivity + streaming provider ("Nimbus" — mobile + broadband + streaming bundle). Secondary user: the human service agent who receives escalations.

**Why now:** Agentforce makes it viable to contain tier-1 inquiries with grounded, guardrailed AI, escalating only what needs a human.

**North Star metric:** Containment rate (% of inquiries resolved without human handoff).
**Guardrail metrics:** Groundedness (no hallucinated facts), guardrail-enforcement rate (PII/scope/injection), escalation correctness (right things escalate, wrong things don't).

---

## 2. What This Demonstrates

The goal is to **decompose a business problem into an agent architecture and prove it's safe and measurable** — not just wire one action. This build shows:

1. **Topic decomposition** — 4 topics, each mapping to a distinct business capability.
2. **Deliberate action-type selection** — each topic uses a *different* action type: pick the tool to fit the job, not everything is a prompt.
3. **Guardrails** — scope enforcement, PII redaction, refusals, prompt-injection resistance (the regulated-industry differentiator).
4. **Evals as first-class** — a scored eval set, not happy-path clicks.
5. **Business framing** — containment → deflected cases → $ saved.

---

## 3. Architecture

```
Nimbus Connected Account Assistant (Agentforce Agent)
├── Topic 1: Billing & Payments        → Apex action        (query invoices, compute balance)
├── Topic 2: Plan / Subscription Change → Flow action        (guided change + confirmation write)
├── Topic 3: Service & Outage Status    → Knowledge/Data Cloud grounding (RAG)
└── Topic 4: Troubleshoot → Escalate     → Prompt template + Case creation / human handoff
```

**Action-type rationale (the narration):**
| Topic | Action type | Why this type |
|---|---|---|
| Billing & Payments | **Apex** | Deterministic logic + math; PII handling; never let the LLM compute a balance |
| Plan / Subscription | **Flow** | Transactional write with confirmation/approval; business process, not free text |
| Service & Outage | **Grounding (Data Cloud / Knowledge)** | Factual answers must be grounded + cited; zero hallucination tolerance |
| Troubleshoot → Escalate | **Prompt template + Case** | Judgment + graceful handoff; containment vs. escalation decision |

---

## 4. Data Model

Synthetic data only — **no real PII, no real customer data** (per safety rules). Prefer reusing SDO's preloaded Sales/Service objects where they fit; add custom objects only where needed.

Custom objects (namespaced to the app):
- `Nimbus_Account__c` — customer account (name, tier, contact)
- `Nimbus_Invoice__c` — invoices (amount, due date, status, account lookup)
- `Nimbus_Plan__c` — available plans + current subscription
- `Nimbus_Outage__c` — service/outage records by region (feeds Topic 3 grounding)

Standard object:
- `Case` — used for Topic 4 escalation.

Seed: ~10 synthetic customers with invoices, plans, and a couple of active/resolved outages. Loaded via a seed script in `scripts/`.

---

## 5. Guardrails Layer

Applied across all topics:
- **Scope enforcement** — agent refuses off-topic requests ("I can only help with your Nimbus account").
- **PII redaction** — never echo full card numbers, SSNs; mask account identifiers in responses.
- **Refusal patterns** — no financial advice, no promises of credits without policy backing, no actions outside defined topics.
- **Prompt-injection resistance** — ignore instructions embedded in user input or retrieved documents that try to override system behavior.

Each guardrail has at least one eval case that attempts to violate it.

---

## 6. Eval Harness

`evals/` holds a versioned eval set (~12 cases) + results with timestamps for regression tracking. Run via the `agentforce-test` skill / ADLC QA agent.

**Dimensions scored:**
1. **Action-selection accuracy** — did the agent route to the correct topic/action?
2. **Groundedness** — are factual claims backed by retrieved data (Topic 3)?
3. **Guardrail enforcement** — did it refuse/redact when it should?
4. **Containment rate** — resolved without escalation when appropriate?
5. **Escalation correctness** — escalated when (and only when) it should?

Case mix: happy-path per topic (4), guardrail-violation attempts (3–4), escalation triggers (2), ambiguous/multi-intent (2).

---

## 7. Repo Layout

```
agentforce-account-assistant/
├── force-app/main/default/   # sf metadata: agent, apex, flows, objects, permissions
├── agent/                     # .agent scripts (ADLC author output)
├── data/                      # synthetic seed data (CSV/JSON) + import plan
├── evals/                     # eval set + timestamped results
├── docs/                      # this spec, solution one-pager, PRD, demo script
├── scripts/                   # deploy + seed scripts
└── README.md                  # what it does, how to run, results, architecture diagram
```

---

## 8. Build Sequence

1. **Scaffold + deploy data model** — objects + synthetic seed → deploy to `sdo`.
2. **Author agent + 4 topics** — via ADLC author agent (.agent scripts).
3. **Build the 4 actions** — Apex (billing), Flow (plan change), grounding (outage), prompt+Case (escalation).
4. **Guardrails** — scope/PII/refusal/injection.
5. **Eval harness** — author ~12 cases, run, record results.
6. **Solution artifacts** — one-pager (ROI), demo script, README + architecture diagram.

---

## 9. Scope Discipline (YAGNI)

**In scope:** exactly 4 topics, one action each, ~12 eval cases, ~10 seed customers.

**Out of scope:** auth flows, multi-language, live payment integration, real Slack surface, multi-agent orchestration, production hardening. Enough to demo live and explain the design — not a product.

---

## 10. Success Criteria

- Agent deploys cleanly to `sdo` from version-controlled metadata.
- All 4 topics route correctly on happy-path eval cases.
- Guardrail cases all pass (refuse/redact as designed).
- Eval results recorded in `evals/` with a scored summary.
- One-pager quantifies containment → $ saved.
- The whole thing is narratable: for each topic, *what it does, how it's used, what it depends on.*

---

## 11. Open Dependencies

- SDO feature provisioning must complete: **Data Cloud full setup** (Topic 3 grounding) and **Agentforce Agent Builder 2.0 example agents** (Pronto reference + confirms Agentforce Studio is wired). As of spec-writing these were still provisioning — re-verify before Build Sequence step 2.
