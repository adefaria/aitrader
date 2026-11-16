# 00 - Investor Profile & Allocation Architecture

## Investor Details
- **Investor:** Andrew DeFaria
- **Life Stage:** Entering Retirement (Active Wealth Growth with Systematic Guardrails)
- **Primary Bias:** Heavily weighted toward US Large-Cap Technology, compounders, and secular innovation themes.
- **Diversification Mandate:** Core non-tech allocations to avoid idiosyncratic risk, including Broad Market Index Funds / Mutual Funds, US Treasury Bonds / Fixed Income, and Critical Energy Infrastructure.
- **Risk Tolerance:** **High / Aggressive Growth** with automated downside rules (stop-loss, profit-harvesting, and cash floor).

---

## Target Asset Allocation Framework ($10,000 Portfolio Baseline)

| Asset Class / Bucket | Target % | Allowed Band | Key Vehicles | Investment Rationale |
| :--- | :--- | :--- | :--- | :--- |
| **US Large-Cap Tech** | **45.0%** | 35% – 60% | `NVDA`, `MSFT`, `AVGO`, `AAPL` | High-conviction AI compute, cloud software monopolies, custom silicon, and enterprise cash flow fortresses. |
| **Broad Market / Mutual Funds** | **20.0%** | 15% – 30% | `VOO`, `QQQ`, `VTI` | Low-cost S&P 500 / Nasdaq core index ballast providing broader economic exposure beyond single equities. |
| **Data Center Power & Energy** | **15.0%** | 10% – 20% | `VST`, `CEG` | Power generation and clean nuclear baseload utilities securing long-term contracts with AI hyperscalers. |
| **Fixed Income & Bonds** | **10.0%** | 5% – 20% | `TLT`, `BND`, `SGOV` | 20+ Year US Treasury duration buffer providing yield, deflation protection, and macro rate-cut appreciation for retirement security. |
| **Liquid Cash Reserve** | **10.0%** | 8% – 15% | USD Cash | Dry powder buffer reserved for high-conviction market pullbacks and catalyst opportunities. |

---

## Active Risk Parameters (High Growth / Semi-Aggressive)

- **Single Position Maximum Cap:** 25.0% (No individual stock may exceed $2,500 at cost basis)
- **Sector / Asset Class Maximum Cap:** 50.0% (Total Tech Equities capped at 50% max)
- **Minimum Cash Floor:** 8.0% standard (5.0% only permitted during extreme catalyst score >= 8)
- **Hard Stop-Loss:** -10.0% automatic exit from cost basis
- **Trailing Profit Lock:** +12.0% profit triggers trailing stop at 6.0% below peak high-water mark
- **Portfolio Circuit Breaker:** 12.0% peak-to-trough portfolio drawdown halts all new buy orders
- **Catalyst Entry Threshold:** Minimum score 7 / 10 required to initiate an allocation

---

## How to Edit and Tune Your Profile
You can customize and tune your profile parameters in two places:
1. **Human-Readable Policy & Mandates:** Edit `specs/00-investor-profile.md` and `specs/02-risk-management.md`.
2. **Machine-Readable Engine Settings:** Edit `config/investor_profile.json` (or `.env`), which controls parameters parsed by the Layer 3 execution engine.
