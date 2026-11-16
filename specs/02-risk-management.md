# 02 - Risk Management Rules

## Position Sizing & Cash Reserves
- **Maximum Single-Position Weight:** 20% of total portfolio NAV ($2,000.00 at inception)
- **Maximum Sector Concentration:** 40% of total portfolio NAV
- **Minimum Cash Buffer:** 10% of total portfolio NAV ($1,000.00 at inception)
  - *Exception:* Cash buffer may drop to 5% only when a catalyst scores >= 9/10 with multi-source confirmation

## Exit & Stop-Loss Rules
- **Hard Stop-Loss:** Trigger automatic exit review if a position closes >= 8% below cost basis
- **Trailing Profit Lock:** Once a position gains >= 15%, trail a stop at 7% below its highest closing price
- **Thesis Invalidation:** Exit immediately at next session if the primary news or policy catalyst reverses

## Portfolio-Level Circuit Breakers
- **Max Drawdown Halt:** Pause all new `BUY` orders and flag for manual parameter review if total portfolio NAV drops >= 12% peak-to-trough
- **Underperformance Review:** Flag strategy weights for recalibration if portfolio trails `SPY` by > 5% over a rolling 20-trading-day window
