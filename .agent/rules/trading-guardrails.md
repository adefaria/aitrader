# Workspace Guardrails — AI Trader

1. **Simulation-Only Default:** Never connect to live brokerage order-routing endpoints or execute real-money transactions unless `EXECUTION_MODE=LIVE` is explicitly set by the user.
2. **Deterministic Verification:** All position-size caps, cash floors, stop-loss triggers, and `SPY` benchmark calculations must be verified in Layer 3 execution scripts (`src/`), never solely by LLM arithmetic.
3. **Spec Traceability:** Every simulated trade and daily advisor memo must cite the exact rule IDs from `specs/*.md` and record the active Git commit hash.
