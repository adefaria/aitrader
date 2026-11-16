# 02 - Risk Management Rules

## Tunable Risk & Execution Profiles
The trading engine supports tunable aggressiveness levels. By default, the system operates in **`Semi-Aggressive`** mode:

| Parameter | Conservative | Moderate | Semi-Aggressive *(Active Default)* | Aggressive |
| :--- | :--- | :--- | :--- | :--- |
| **Catalyst Entry Threshold** | Score >= 8 | Score >= 7 | **Score >= 7** | Score >= 6 |
| **Hard Stop-Loss** | -6.0% | -8.0% | **-10.0%** | -12.0% |
| **Trailing Profit Lock** | +10% gain (5% trail) | +15% gain (7% trail) | **+12% gain (6% trail)** | +10% gain (5% trail) |
| **Minimum Cash Floor** | 15.0% | 10.0% (5% if score >= 9) | **8.0% (5% if score >= 8)** | 5.0% |
| **Single-Position Cap** | 15.0% | 20.0% | **25.0%** | 30.0% |
| **Sector / Class Cap** | 35.0% | 40.0% | **45.0%** | 50.0% |
| **Scale-In / Add to Position** | Disabled | Score >= 9 only | **Score >= 8 (up to pos cap)** | Score >= 7 (up to cap) |

## Position Sizing & Cash Reserves
- **Maximum Single-Position Weight:** Governed by active risk profile (25% in Semi-Aggressive mode; $2,500.00 baseline).
- **Maximum Sector / Asset Class Cap:** Governed by active risk profile (45% in Semi-Aggressive mode).
- **Minimum Cash Buffer:** Governed by active risk profile (8% standard, 5% for high-conviction catalysts >= 8 in Semi-Aggressive mode).
- **Position Scaling (Add More):** When a high-conviction catalyst affirms an existing position, the engine may purchase additional shares up to the single-position cap, logging explicit rationale (e.g., adding to winners on contract expansion).

## Exit & Stop-Loss Rules
- **Hard Stop-Loss:** Automatic exit if a position drops below the profile stop threshold (-10% in Semi-Aggressive mode) to cut losses cleanly.
- **Trailing Profit Lock:** Once a position gains >= 12% above cost basis, trail a stop at 6% below peak price to actively harvest successes.
- **Thesis Invalidation:** Exit immediately if the primary regulatory, earnings, or macro catalyst is formally invalidated.

## Portfolio-Level Circuit Breakers
- **Max Drawdown Halt:** Pause all new `BUY` orders if portfolio drawdown exceeds 12% peak-to-trough.
- **Underperformance Review:** Flag strategy weights for review if portfolio trails `SPY` by > 5% over a rolling 20-trading-day window.
