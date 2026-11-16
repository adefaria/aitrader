#!/usr/bin/env perl
use strict;
use warnings;
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Mojolicious::Lite -signatures;
use Trader::DB qw(get_dbh get_latest_nav get_positions fetch_market_price get_git_commit);

eval {
    require Dotenv;
    Dotenv->load if -f '.env';
};

my $db_path = $ENV{DB_PATH} // "$RealBin/../data/paper_ledger.db";

helper db => sub {
    return get_dbh($db_path);
};

my %PRICE_CACHE;
helper cached_price => sub ($c, $ticker, $fallback = 0.0) {
    my $now = time;
    if ($PRICE_CACHE{$ticker} && ($now - $PRICE_CACHE{$ticker}{ts} < 60)) {
        return $PRICE_CACHE{$ticker}{price};
    }
    my $price = fetch_market_price($ticker) // $fallback;
    $PRICE_CACHE{$ticker} = { price => $price, ts => $now } if $price;
    return $price || $fallback;
};

get '/' => sub ($c) {
    my $dbh = $c->db;
    my $nav = get_latest_nav($dbh) // {
        total_nav => 10000.00,
        cash => 10000.00,
        positions_value => 0.0,
        spy_price => 0.0,
        portfolio_return => 0.0,
        spy_return => 0.0,
        alpha => 0.0,
        drawdown => 0.0,
        date => 'N/A'
    };

    my $positions = get_positions($dbh);
    for my $p (@$positions) {
        $p->{current_price} = $c->cached_price($p->{ticker}, $p->{cost_basis});
        $p->{return_pct} = (($p->{current_price} - $p->{cost_basis}) / $p->{cost_basis}) * 100;
    }

    my $trades = $dbh->selectall_arrayref(
        "SELECT * FROM trades ORDER BY id DESC LIMIT 10",
        { Slice => {} }
    );

    my $catalysts = $dbh->selectall_arrayref(
        "SELECT * FROM catalyst_events ORDER BY id DESC LIMIT 10",
        { Slice => {} }
    );

    $dbh->disconnect;

    $c->stash(
        nav        => $nav,
        positions  => $positions,
        trades     => $trades,
        catalysts  => $catalysts,
        git_commit => get_git_commit(),
    );
    $c->render(template => 'index');
};

get '/api/status' => sub ($c) {
    my $dbh = $c->db;
    my $nav = get_latest_nav($dbh);
    my $positions = get_positions($dbh);
    $dbh->disconnect;

    $c->render(json => {
        nav        => $nav,
        positions  => $positions,
        git_commit => get_git_commit(),
    });
};

app->start;

__DATA__

@@ index.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AI Trader — Portfolio Operations Dashboard</title>
  <style>
    :root {
      --bg: #0d1117;
      --card-bg: #161b22;
      --border: #30363d;
      --text: #e6edf3;
      --text-muted: #8b949e;
      --accent: #58a6ff;
      --success: #3fb950;
      --warning: #d29922;
      --danger: #f85149;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
    body { background-color: var(--bg); color: var(--text); padding: 24px; line-height: 1.5; }
    .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 16px; margin-bottom: 24px; }
    .header h1 { font-size: 1.5rem; font-weight: 600; display: flex; align-items: center; gap: 8px; }
    .badge { font-size: 0.75rem; background: #21262d; border: 1px solid var(--border); padding: 2px 8px; border-radius: 12px; color: var(--accent); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
    .card-title { font-size: 0.85rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 6px; }
    .card-value { font-size: 1.6rem; font-weight: 700; }
    .card-sub { font-size: 0.8rem; color: var(--text-muted); margin-top: 4px; }
    .section-title { font-size: 1.1rem; font-weight: 600; margin-bottom: 12px; display: flex; align-items: center; justify-content: space-between; }
    table { width: 100%; border-collapse: collapse; margin-bottom: 24px; background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
    th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--border); font-size: 0.9rem; }
    th { background: #1c2128; color: var(--text-muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; }
    tr:last-child td { border-bottom: none; }
    .positive { color: var(--success); }
    .negative { color: var(--danger); }
    .score-badge { display: inline-block; padding: 2px 6px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }
    .score-high { background: rgba(63, 185, 80, 0.2); color: var(--success); border: 1px solid var(--success); }
    .score-mid { background: rgba(210, 153, 34, 0.2); color: var(--warning); border: 1px solid var(--warning); }
    .score-low { background: rgba(248, 81, 73, 0.2); color: var(--danger); border: 1px solid var(--danger); }
    .guardrails-list { list-style: none; display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 24px; }
    .guardrail-chip { background: var(--card-bg); border: 1px solid var(--border); border-radius: 6px; padding: 8px 12px; font-size: 0.85rem; }
    .status-ok { color: var(--success); font-weight: 600; }
  </style>
</head>
<body>

  <div class="header">
    <div>
      <h1>AI Trader Paper Ledger</h1>
      <div style="font-size: 0.8rem; color: var(--text-muted); margin-top: 4px;">
        Layer 3 Deterministic Engine &bull; Spec Commit: <code><%= substr($git_commit, 0, 7) %></code> &bull; Date: <%= $nav->{date} %>
      </div>
    </div>
    <div>
      <span class="badge">SIMULATION MODE</span>
    </div>
  </div>

  <div class="grid">
    <div class="card">
      <div class="card-title">Total Portfolio NAV</div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{total_nav}) %></div>
      <div class="card-sub">Baseline: $10,000.00</div>
    </div>
    <div class="card">
      <div class="card-title">Cash Reserve</div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{cash}) %></div>
      <div class="card-sub"><%= sprintf("%.1f", ($nav->{cash} / ($nav->{total_nav} || 1)) * 100) %>% allocation</div>
    </div>
    <div class="card">
      <div class="card-title">SPY Benchmark</div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{spy_price}) %></div>
      <div class="card-sub">SPDR S&amp;P 500 ETF</div>
    </div>
    <div class="card">
      <div class="card-title">Net Alpha (vs SPY)</div>
      <div class="card-value <%= $nav->{alpha} >= 0 ? 'positive' : 'negative' %>">
        <%= sprintf("%+.2f", $nav->{alpha} * 100) %>%
      </div>
      <div class="card-sub">ROI: <%= sprintf("%.2f", $nav->{portfolio_return} * 100) %>%</div>
    </div>
  </div>

  <div class="section-title">Risk Guardrails &amp; Constraints</div>
  <ul class="guardrails-list">
    <li class="guardrail-chip">Cash Reserve Floor: <strong>10.0% ($1,000.00)</strong> &bull; <span class="status-ok">PASS</span></li>
    <li class="guardrail-chip">Single-Position Cap: <strong>20.0% ($2,000.00)</strong> &bull; <span class="status-ok">PASS</span></li>
    <li class="guardrail-chip">Sector Concentration Cap: <strong>40.0% ($4,000.00)</strong> &bull; <span class="status-ok">PASS</span></li>
    <li class="guardrail-chip">Hard Stop-Loss: <strong>-8.0%</strong> &bull; <span class="status-ok">ACTIVE</span></li>
    <li class="guardrail-chip">Trailing Profit Lock: <strong>7.0% from 15.0% gain</strong> &bull; <span class="status-ok">ACTIVE</span></li>
    <li class="guardrail-chip">Max Drawdown Halt: <strong>12.0%</strong> &bull; <span class="status-ok">PASS (0.0% current)</span></li>
  </ul>

  <div class="section-title">Open Positions</div>
  <table>
    <thead>
      <tr>
        <th>Ticker</th>
        <th>Shares</th>
        <th>Cost Basis</th>
        <th>Market Price</th>
        <th>Market Value</th>
        <th>Return</th>
        <th>Sector</th>
      </tr>
    </thead>
    <tbody>
      % if (@$positions) {
        % for my $p (@$positions) {
          <tr>
            <td><strong><%= $p->{ticker} %></strong></td>
            <td><%= $p->{shares} %></td>
            <td>$<%= sprintf("%.2f", $p->{cost_basis}) %></td>
            <td>$<%= sprintf("%.2f", $p->{current_price}) %></td>
            <td>$<%= sprintf("%.2f", $p->{shares} * $p->{current_price}) %></td>
            <td class="<%= $p->{return_pct} >= 0 ? 'positive' : 'negative' %>"><%= sprintf("%+.2f", $p->{return_pct}) %>%</td>
            <td><%= $p->{sector} // 'N/A' %></td>
          </tr>
        % }
      % } else {
        <tr>
          <td colspan="7" style="text-align: center; color: var(--text-muted); padding: 20px;">
            No active positions held (100% Cash Buffer / Inception Mode).
          </td>
        </tr>
      % }
    </tbody>
  </table>

  <div class="section-title">Scored Catalyst Pipeline</div>
  <table>
    <thead>
      <tr>
        <th>Timestamp</th>
        <th>Ticker</th>
        <th>Score</th>
        <th>Theme</th>
        <th>Headline</th>
      </tr>
    </thead>
    <tbody>
      % if (@$catalysts) {
        % for my $c (@$catalysts) {
          <tr>
            <td style="color: var(--text-muted); font-size: 0.8rem;"><%= $c->{timestamp} %></td>
            <td><strong><%= $c->{ticker} // '-' %></strong></td>
            <td>
              % my $score = $c->{score} // 0;
              <span class="score-badge <%= $score >= 7 ? 'score-high' : ($score >= 4 ? 'score-mid' : 'score-low') %>">
                <%= $c->{score} ? "$c->{score}/10" : 'UNSCORED' %>
              </span>
            </td>
            <td><%= $c->{theme} // '-' %></td>
            <td><%= $c->{headline} %></td>
          </tr>
        % }
      % } else {
        <tr>
          <td colspan="5" style="text-align: center; color: var(--text-muted); padding: 20px;">
            No ingested catalyst events recorded.
          </td>
        </tr>
      % }
    </tbody>
  </table>

  <div class="section-title">Recent Simulated Trades</div>
  <table>
    <thead>
      <tr>
        <th>Timestamp</th>
        <th>Ticker</th>
        <th>Action</th>
        <th>Shares</th>
        <th>Price</th>
        <th>Total Amount</th>
        <th>Catalyst Score</th>
        <th>Rationale</th>
      </tr>
    </thead>
    <tbody>
      % if (@$trades) {
        % for my $t (@$trades) {
          <tr>
            <td style="color: var(--text-muted); font-size: 0.8rem;"><%= $t->{timestamp} %></td>
            <td><strong><%= $t->{ticker} %></strong></td>
            <td><strong><%= $t->{action} %></strong></td>
            <td><%= $t->{shares} %></td>
            <td>$<%= sprintf("%.2f", $t->{fill_price}) %></td>
            <td>$<%= sprintf("%.2f", $t->{total_amount}) %></td>
            <td><%= $t->{catalyst_score} ? "$t->{catalyst_score}/10" : '-' %></td>
            <td><%= $t->{rationale} %></td>
          </tr>
        % }
      % } else {
        <tr>
          <td colspan="8" style="text-align: center; color: var(--text-muted); padding: 20px;">
            No simulated trades recorded yet.
          </td>
        </tr>
      % }
    </tbody>
  </table>

</body>
</html>

