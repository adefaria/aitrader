# AGENTS.md — 3-Layer Trading Agent Architecture

This workspace operates under a strict **3-Layer Architecture** separating human-defined investment policy from probabilistic LLM reasoning and deterministic execution.

---

## Layer 1: Directives (Strategy & Risk Specifications)
**Location:** `specs/*.md` and `.agent/rules/trading-guardrails.md`

- **Source of Truth:** Every decision, position size, catalyst score, and exit check MUST obey the active Markdown files in `specs/`:
  - `specs/01-investment-mandate.md` — Capital baseline ($10,000), `SPY` benchmark, tradeable universe, and 5–45 day holding horizon.
  - `specs/02-risk-management.md` — Max 20% single-position cap, 40% sector cap, 10% cash reserve floor, 8% hard stop-loss, 15%/7% trailing profit lock, and 12% portfolio drawdown circuit breaker.
  - `specs/03-catalyst-weights.md` — 1–10 catalyst scoring rubric and thematic weights (AI Silicon & Supply Chain; Data Center Power, Grid & Political Friction; Macro & Rate Sensitivity).
- **Immutability Rule:** The agent MUST NOT silently alter risk limits or universe exclusions in `specs/*.md` during a simulation run. Parameter updates require explicit user approval and a Git commit so performance changes can be audited.

---

## Layer 2: Orchestration (Agent Reasoning & Synthesis)
**Role:** Antigravity Agent / Gemini Model

- **Daily Workflow Sequence:**
  1. **Load State:** Read current cash, open positions, cost basis, and high-water marks from `data/paper_ledger.db` (or latest state snapshot).
  2. **Check Risk & Exits First:** Evaluate all open positions against `specs/02-risk-management.md` (hard stops, trailing stops, thesis invalidation, and portfolio drawdown circuit breaker) BEFORE evaluating any new buys.
  3. **Ingest & Score Catalysts:** Review the past 24 hours of ingested financial, regulatory, supply-chain, and state/municipal policy news. Score each candidate event from `1` to `10` using `specs/03-catalyst-weights.md`. Discard anything scoring `< 7`.
  4. **Size & Propose Allocations:** For candidates scoring `>= 7`, verify universe eligibility (`specs/01-investment-mandate.md`), sector concentration (`<= 40%`), single-position cap (`<= 20%`), and minimum cash reserve (`>= 10%`, or `>= 5%` only for score `>= 9`).
  5. **Execute & Report:** Dispatch validated orders to Layer 3 execution scripts and generate the daily briefing comparing portfolio NAV against `SPY`.
- **Guardrail Enforcement:** Never emit live brokerage order calls unless `EXECUTION_MODE=LIVE` is explicitly configured and confirmed by the user. Default is strictly `SIMULATION` / `ADVISOR_BRIEF`.

---

## Layer 3: Execution (Deterministic Scripts & Ledger)
**Location:** `src/` and `data/`

- **Separation of Concerns:** LLMs handle qualitative news synthesis and thesis scoring; deterministic scripts (`Python` or `Perl`) handle market-price retrieval, arithmetic, risk validation, SQLite ledger writes, and benchmark math.
- **Required Modules:**
  - `src/ingest_news.py` — Fetches structured articles/filings from configured news/SEC/RSS APIs and stores deduplicated items in `data/`.
  - `src/evaluate_catalysts.py` — Passes normalized news batches + `specs/*.md` to the Gemini API using structured JSON output matching the 1–10 rubric.
  - `src/portfolio_engine.py` — Validates proposed trades independently against `specs/02-risk-management.md` (hard-coded assertions), records simulated fills in `data/paper_ledger.db`, and computes daily `Portfolio_ROI` vs. `SPY_ROI`.
  - `src/generate_report.py` — Outputs daily Markdown briefings in `data/reports/YYYY-MM-DD.md` (both simulation ledger summary and advisor-ready rationale).
- **Auditability:** Every simulated trade row in `data/paper_ledger.db` must store `timestamp`, `ticker`, `action`, `shares`, `fill_price`, `catalyst_score`, `spec_version` (Git commit hash), and `rationale`.
