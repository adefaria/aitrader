# 01 - Investment Mandate

## Capital & Benchmark
- **Starting Capital:** $10,000.00 USD (simulated paper account)
- **Primary Benchmark:** SPDR S&P 500 ETF (`SPY`) total return from inception date
- **Evaluation Metric:** Net portfolio alpha (`Portfolio_ROI - SPY_ROI`) measured daily, weekly, and monthly

## Tradeable Universe
- **Allowed:** US-listed equities and liquid sector ETFs
- **Excluded:**
  - Penny stocks (share price < $5.00 or average daily volume < 500,000 shares)
  - Leveraged or inverse ETFs (Phase 1)
  - Options, futures, or margin borrowing (Phase 1)

## Holding Horizon & Turnover
- **Target Horizon:** Swing-to-position trades (5 to 45 trading days)
- **Trading Cadence:** Evaluated once daily after market close (or pre-market) based on multi-day fundamental and policy catalysts
- **Anti-Churn Rule:** Do not exit a position on intraday noise unless a hard risk rule or thesis-invalidation trigger fires

## Execution Modes
- **`SIMULATION` (Default):** Logs simulated orders, fills, and daily NAV to local SQLite/Alpaca Paper ledger
- **`ADVISOR_BRIEF`:** Generates structured trade memos (ticker, direction, allocation %, catalyst thesis, entry/stop/target levels) for review with financial advisor
