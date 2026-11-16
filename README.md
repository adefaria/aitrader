# AI Trader — Autonomous News-Driven Simulation & Advisor Engine

An individually tailored, spec-driven trading simulation and market-intelligence engine built for **Google Antigravity** and Linux environments.

## Overview
- **Goal:** Simulate a **$10,000.00 USD** paper portfolio targeting risk-adjusted outperformance (`alpha`) over the SPDR S&P 500 ETF (`SPY`) using multi-day fundamental, supply-chain, and policy catalysts.
- **Modes:**
  - `SIMULATION` (Default): Executes paper trades against a local SQLite ledger (or Alpaca Paper Trading API) and marks positions to market daily.
  - `ADVISOR_BRIEF`: Generates structured, auditable allocation memos (thesis, entry/stop/target levels, risk notes) for review with a financial advisor.

## Directory Layout
```text
ai-trader/
├── README.md                         # Project overview and quickstart
├── AGENTS.md                         # 3-layer agent architecture (Directive / Orchestration / Execution)
├── specs/
│   ├── 01-investment-mandate.md      # $10k baseline, SPY benchmark, asset universe, holding horizon
│   ├── 02-risk-management.md         # Position caps, cash floor, stop-loss, drawdown circuit breakers
│   └── 03-catalyst-weights.md        # Scoring rules for NVDA/semi news & data center ballot/grid friction
├── src/                              # Layer 3 deterministic execution scripts (Python/Perl)
├── data/                             # Local SQLite paper ledger, historical snapshots, and daily reports
└── .agent/
    └── rules/
        └── trading-guardrails.md     # Workspace safety rule enforcing simulation-only defaults
```

## Quickstart
1. Extract this archive into your workspace (e.g., `~/projects/ai-trader`) and initialize Git:
   ```bash
   tar -xzvf ai-trader-starter.tar.gz
   cd ai-trader && git init && git add . && git commit -m "Initial strategy specs and agent architecture"
   ```
2. Open the directory in **Google Antigravity**.
3. Tune the numerical thresholds and catalyst themes in `specs/*.md`.
4. Ask Antigravity to scaffold the Layer 3 scripts in `src/` (`ingest_news.py`, `evaluate_catalysts.py`, `portfolio_engine.py`, `generate_report.py`) adhering strictly to `AGENTS.md`.
