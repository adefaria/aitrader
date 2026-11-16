# 01 - Investment Mandate

## Capital & Benchmark
- **Starting Capital:** $10,000.00 USD (simulated paper account)
- **Primary Benchmark:** SPDR S&P 500 ETF (`SPY`) total return from inception date
- **Evaluation Metric:** Net portfolio alpha (`Portfolio_ROI - SPY_ROI`) measured daily, weekly, and monthly

## Tradeable Universe
- **Allowed Asset Classes:**
  - **US Equities & Sector ETFs:** AI silicon, hyperscalers, power utilities, electrical equipment (e.g., `NVDA`, `AVGO`, `CEG`, `VST`, `ETN`).
  - **Bonds & Fixed Income:** US Treasuries, corporate bonds, inflation-protected and aggregate debt instruments (e.g., `TLT`, `IEF`, `LQD`, `BND`).
  - **Mutual Funds & Broad Index Funds:** Low-cost index funds and core liquid mutual fund / ETF proxies (e.g., `VOO`, `VTI`, `QQQ`, `FXAIX`, `VTSAX`).
  - **Exotic & Alternative Investments:**
    - Nuclear & Uranium energy transition commodities (e.g., `URA`, `CCJ`).
    - Physical commodity & precious metal trusts (e.g., `GLD`, `SLV`).
    - Digital asset & crypto spot ETFs (e.g., `IBIT`, `ETHE`).
    - Digital infrastructure & data center REITs (e.g., `EQIX`, `DLR`).
- **Excluded:**
  - Penny stocks (share price < $5.00 or micro-cap illiquid vehicles)
  - Leveraged 3x inverse instruments or unhedged margin borrowing
  - Illiquid private placements or unregulated OTC pink sheets

## Holding Horizon & Turnover
- **Target Horizon:** Swing-to-position trades (5 to 45 trading days)
- **Trading Cadence:** Evaluated once daily after market close (or pre-market) based on multi-day fundamental and policy catalysts
- **Anti-Churn Rule:** Do not exit a position on intraday noise unless a hard risk rule or thesis-invalidation trigger fires

## Execution Modes
- **`SIMULATION` (Default):** Logs simulated orders, fills, and daily NAV to local SQLite/Alpaca Paper ledger
- **`ADVISOR_BRIEF`:** Generates structured trade memos (ticker, direction, allocation %, catalyst thesis, entry/stop/target levels) for review with financial advisor
