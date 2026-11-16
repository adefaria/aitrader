#!/usr/bin/env perl
use strict;
use warnings;
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Mojolicious::Lite -signatures;
use Trader::DB qw(
    get_dbh get_latest_nav get_positions fetch_market_price
    fetch_market_indices get_git_commit
);

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

my ($INDICES_CACHE, $INDICES_CACHE_TIME);
helper cached_indices => sub ($c) {
    my $now = time;
    if ($INDICES_CACHE && ($now - ($INDICES_CACHE_TIME // 0) < 60)) {
        return $INDICES_CACHE;
    }
    my $indices = fetch_market_indices();
    if ($indices && @$indices) {
        $INDICES_CACHE = $indices;
        $INDICES_CACHE_TIME = $now;
    }
    return $INDICES_CACHE // [
        {
            name   => 'DOW',
            symbol => '^DJI',
            url    => 'https://www.marketwatch.com/investing/index/djia?mod=home_markets',
            price  => 0.0,
            change => 0.0,
            pct    => 0.0
        },
        {
            name   => 'S&P 500',
            symbol => '^GSPC',
            url    => 'https://www.marketwatch.com/investing/index/spx?mod=home_markets',
            price  => 0.0,
            change => 0.0,
            pct    => 0.0
        },
        {
            name   => 'NASDAQ',
            symbol => '^IXIC',
            url    => 'https://www.marketwatch.com/investing/index/comp?mod=home_markets',
            price  => 0.0,
            change => 0.0,
            pct    => 0.0
        },
    ];
};

get '/favicon.svg' => sub ($c) {
    $c->res->headers->content_type('image/svg+xml');
    $c->reply->file("$RealBin/../public/favicon.svg");
};

get '/favicon.ico' => sub ($c) {
    $c->res->headers->content_type('image/x-icon');
    $c->reply->file("$RealBin/../public/favicon.ico");
};

get '/favicon-32x32.png' => sub ($c) {
    $c->res->headers->content_type('image/png');
    $c->reply->file("$RealBin/../public/favicon-32x32.png");
};

get '/favicon-16x16.png' => sub ($c) {
    $c->res->headers->content_type('image/png');
    $c->reply->file("$RealBin/../public/favicon-16x16.png");
};

get '/apple-touch-icon.png' => sub ($c) {
    $c->res->headers->content_type('image/png');
    $c->reply->file("$RealBin/../public/apple-touch-icon.png");
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
        $p->{market_val} = $p->{shares} * $p->{current_price};
    }

    my $trades = $dbh->selectall_arrayref(
        "SELECT * FROM trades ORDER BY id DESC LIMIT 25",
        { Slice => {} }
    );

    my $catalysts = $dbh->selectall_arrayref(
        "SELECT * FROM catalyst_events ORDER BY id DESC LIMIT 15",
        { Slice => {} }
    );

    $dbh->disconnect;

    my $indices = $c->cached_indices();

    $c->stash(
        nav        => $nav,
        positions  => $positions,
        trades     => $trades,
        catalysts  => $catalysts,
        indices    => $indices,
        git_commit => get_git_commit(),
    );
    $c->render(template => 'index');
};

get '/api/status' => sub ($c) {
    my $dbh = $c->db;
    my $nav = get_latest_nav($dbh);
    my $positions = get_positions($dbh);
    $dbh->disconnect;
    my $indices = $c->cached_indices();

    $c->render(json => {
        nav        => $nav,
        positions  => $positions,
        indices    => $indices,
        git_commit => get_git_commit(),
    });
};

post '/api/evaluate' => sub ($c) {
    my $cmd = "perl -Ilocal/lib/perl5 -I$RealBin/lib $RealBin/run_daily.pl 2>&1";
    my $output = `$cmd`;
    my $exit_code = $? >> 8;

    if ($exit_code == 0) {
        %PRICE_CACHE = ();
        $INDICES_CACHE = undef;
        $c->render(json => {
            success => 1,
            message => 'Market evaluation and catalyst execution completed successfully.',
            output  => $output,
        });
    } else {
        $c->render(status => 500, json => {
            success => 0,
            message => "Market evaluation failed with exit code $exit_code.",
            output  => $output,
        });
    }
};

app->start;

__DATA__

@@ index.html.ep
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AI Trader</title>
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2NCA2NCIgd2lkdGg9IjY0IiBoZWlnaHQ9IjY0Ij4KICA8cmVjdCB3aWR0aD0iNjQiIGhlaWdodD0iNjQiIHJ4PSIxNCIgZmlsbD0iIzA5MGMxMCIvPgogIDwhLS0gTGVmdCBDYW5kbGVzdGljayAoQnVsbGlzaCBHcmVlbikgLS0+CiAgPGxpbmUgeDE9IjE4IiB5MT0iMTQiIHgyPSIxOCIgeTI9IjUwIiBzdHJva2U9IiMyZWEwNDMiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgPHJlY3QgeD0iMTQiIHk9IjI0IiB3aWR0aD0iOCIgaGVpZ2h0PSIyNCIgcng9IjIiIGZpbGw9IiMyZWEwNDMiLz4KICA8IS0tIENlbnRlciBDYW5kbGVzdGljayAoVGVjaCAvIERlcHRoIEJsdWUpIC0tPgogIDxsaW5lIHgxPSIzMiIgeTE9IjEwIiB4Mj0iMzIiIHkyPSI0NCIgc3Ryb2tlPSIjMzg4YmZkIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogIDxyZWN0IHg9IjI4IiB5PSIxOCIgd2lkdGg9IjgiIGhlaWdodD0iMjAiIHJ4PSIyIiBmaWxsPSIjMzg4YmZkIi8+CiAgPCEtLSBSaWdodCBDYW5kbGVzdGljayAoQnVsbGlzaCBHcmVlbikgLS0+CiAgPGxpbmUgeDE9IjQ2IiB5MT0iMjAiIHgyPSI0NiIgeTI9IjU0IiBzdHJva2U9IiMyZWEwNDMiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgPHJlY3QgeD0iNDIiIHk9IjI4IiB3aWR0aD0iOCIgaGVpZ2h0PSIyMCIgcng9IjIiIGZpbGw9IiMyZWEwNDMiLz4KICA8IS0tIENvbnRyYXN0IGhhbG8gYXJvdW5kIHVwd2FyZCB0cmVuZCBsaW5lIC0tPgogIDxwYXRoIGQ9Ik0xMSA0NCBMMjUgMzAgTDM3IDM2IEw1MiAxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDkwYzEwIiBzdHJva2Utd2lkdGg9IjcuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+CiAgPGNpcmNsZSBjeD0iNTIiIGN5PSIxNCIgcj0iNi41IiBmaWxsPSIjMDkwYzEwIi8+CiAgPCEtLSBWaWJyYW50IEdyZWVuIFVwd2FyZCBHcmFwaCBMaW5lIC0tPgogIDxwYXRoIGQ9Ik0xMSA0NCBMMjUgMzAgTDM3IDM2IEw1MiAxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDBlNjc2IiBzdHJva2Utd2lkdGg9IjQuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+CiAgPGNpcmNsZSBjeD0iNTIiIGN5PSIxNCIgcj0iNC41IiBmaWxsPSIjMDBlNjc2Ii8+Cjwvc3ZnPg==">
  <link rel="icon" type="image/svg+xml" href="favicon.svg?v=20261116b">
  <link rel="icon" type="image/png" sizes="32x32" href="favicon-32x32.png?v=20261116b">
  <link rel="icon" type="image/png" sizes="16x16" href="favicon-16x16.png?v=20261116b">
  <link rel="apple-touch-icon" sizes="180x180" href="apple-touch-icon.png?v=20261116b">
  <link rel="shortcut icon" href="favicon.ico?v=20261116b">
  <style>
    /* Theme color definitions with charcoal & black accents */
    :root[data-theme="dark"] {
      --bg: #090c10;
      --card-bg: #12161f;
      --card-inner: #1a202c;
      --border: #272e3b;
      --border-subtle: #1c222c;
      --text: #f0f6fc;
      --text-muted: #8b949e;
      --accent-charcoal: #21262d;
      --accent-black: #010409;
      --accent-primary: #388bfd;
      --accent-hover: #1f242c;
      --success: #3fb950;
      --danger: #f85149;
      --warning: #d29922;
      --shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
      --badge-bg: #1c2128;
    }

    :root[data-theme="light"] {
      --bg: #f6f8fa;
      --card-bg: #ffffff;
      --card-inner: #f1f4f8;
      --border: #d0d7de;
      --border-subtle: #eaeef2;
      --text: #1f2328;
      --text-muted: #656d76;
      --accent-charcoal: #24292f;
      --accent-black: #0f141c;
      --accent-primary: #0969da;
      --accent-hover: #ebeff4;
      --success: #1a7f37;
      --danger: #cf222e;
      --warning: #9a6700;
      --shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
      --badge-bg: #eaeef2;
    }

    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
    body { background-color: var(--bg); color: var(--text); padding: 24px; line-height: 1.5; transition: background-color 0.2s ease, color 0.2s ease; }

    /* Top Market Indices Bar with MarketWatch Links */
    .indices-strip {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 12px;
      margin-bottom: 24px;
    }
    .index-card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 12px 16px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      box-shadow: var(--shadow);
      text-decoration: none;
      color: inherit;
      transition: transform 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease;
      cursor: pointer;
    }
    .index-card:hover {
      transform: translateY(-2px);
      border-color: var(--accent-primary);
      box-shadow: 0 6px 16px rgba(0, 0, 0, 0.2);
    }
    .index-info .name {
      font-size: 0.85rem;
      font-weight: 700;
      text-transform: uppercase;
      color: var(--text-muted);
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .index-info .name .link-icon {
      font-size: 0.75rem;
      opacity: 0.6;
    }
    .index-info .symbol { font-size: 0.75rem; color: var(--text-muted); margin-top: 2px; }
    .index-metrics { text-align: right; }
    .index-price { font-size: 1.2rem; font-weight: 700; font-family: monospace; }
    .index-change { font-size: 0.8rem; font-weight: 600; margin-top: 2px; }

    /* Main Header */
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      border-bottom: 1px solid var(--border);
      padding-bottom: 16px;
      margin-bottom: 24px;
      flex-wrap: wrap;
      gap: 16px;
    }
    .header-title-box { display: flex; align-items: center; gap: 12px; }
    .header-logo { width: 32px; height: 32px; vertical-align: middle; }
    .header h1 { font-size: 1.75rem; font-weight: 800; letter-spacing: -0.5px; }
    .tag-badge {
      font-size: 0.75rem;
      background: var(--badge-bg);
      border: 1px solid var(--border);
      padding: 3px 8px;
      border-radius: 6px;
      color: var(--text-muted);
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .header-actions { display: flex; align-items: center; gap: 12px; }

    /* Buttons & Theme Dropdown */
    .btn {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 16px;
      border-radius: 6px;
      font-size: 0.85rem;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.15s ease;
      border: 1px solid var(--border);
    }
    .btn-evaluate {
      background: var(--accent-charcoal);
      color: #ffffff;
      border-color: var(--accent-charcoal);
    }
    .btn-evaluate:hover { opacity: 0.9; }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }

    /* Icon-only Theme Dropdown Menu (matching jobhunt / defaria apps) */
    .theme-dropdown {
      position: relative;
      display: inline-block;
    }
    .btn-theme.icon-only {
      padding: 0;
      width: 38px;
      height: 38px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-size: 1.15rem;
      line-height: 1;
      background: var(--card-inner);
      border: 1px solid var(--border);
      color: var(--text);
      border-radius: 6px;
      cursor: pointer;
      box-shadow: var(--shadow);
      transition: all 0.15s ease;
    }
    .btn-theme.icon-only:hover {
      background: var(--accent-hover);
      border-color: var(--accent-primary);
    }
    .theme-menu {
      position: absolute;
      top: calc(100% + 6px);
      right: 0;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
      padding: 6px;
      min-width: 135px;
      z-index: 1000;
      display: none;
      flex-direction: column;
      gap: 2px;
    }
    .theme-menu.active {
      display: flex;
    }
    .theme-menu-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      font-size: 0.85rem;
      font-weight: 500;
      color: var(--text);
      background: transparent;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      text-align: left;
      transition: background 0.1s ease;
      width: 100%;
    }
    .theme-menu-item:hover {
      background: var(--accent-hover);
      color: var(--accent-primary);
    }
    .theme-menu-item.active {
      background: var(--accent-hover);
      color: var(--accent-primary);
      font-weight: 700;
    }
    .theme-menu-item .check {
      margin-left: auto;
      font-size: 0.8rem;
      opacity: 0;
    }
    .theme-menu-item.active .check {
      opacity: 1;
    }

    /* Primary Stats Grid */
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; padding: 16px; box-shadow: var(--shadow); }
    .card-title { font-size: 0.8rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 6px; font-weight: 600; }
    .card-value { font-size: 1.7rem; font-weight: 800; font-family: monospace; }
    .card-sub { font-size: 0.8rem; color: var(--text-muted); margin-top: 4px; }

    /* Strategy / Posture Banner */
    .posture-banner {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-left: 4px solid var(--accent-charcoal);
      border-radius: 6px;
      padding: 14px 18px;
      margin-bottom: 24px;
      font-size: 0.85rem;
      color: var(--text);
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      gap: 16px;
    }
    .posture-item strong { color: var(--text); }

    /* Tables */
    .section-title { font-size: 1.1rem; font-weight: 700; margin-bottom: 12px; display: flex; align-items: center; justify-content: space-between; }
    .table-container { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; overflow-x: auto; margin-bottom: 28px; box-shadow: var(--shadow); }
    table { width: 100%; border-collapse: collapse; text-align: left; }
    th, td { padding: 12px 16px; border-bottom: 1px solid var(--border); font-size: 0.88rem; }
    th { background: var(--card-inner); color: var(--text-muted); font-weight: 700; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.5px; }
    tr:last-child td { border-bottom: none; }
    tbody tr:hover { background: var(--accent-hover); }

    .positive { color: var(--success); font-weight: 600; }
    .negative { color: var(--danger); font-weight: 600; }
    .score-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-weight: 700; font-size: 0.8rem; }
    .score-high { background: rgba(63, 185, 80, 0.15); color: var(--success); border: 1px solid var(--success); }
    .score-mid { background: rgba(210, 153, 34, 0.15); color: var(--warning); border: 1px solid var(--warning); }
    .score-low { background: rgba(248, 81, 73, 0.15); color: var(--danger); border: 1px solid var(--danger); }
    .action-buy { color: var(--success); font-weight: 800; }
    .action-sell { color: var(--danger); font-weight: 800; }

    /* Toast Notification */
    #toast {
      display: none;
      position: fixed;
      bottom: 24px;
      right: 24px;
      background: var(--accent-charcoal);
      color: #ffffff;
      padding: 14px 20px;
      border-radius: 6px;
      font-size: 0.9rem;
      font-weight: 600;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5);
      z-index: 1000;
      animation: fadeIn 0.3s;
    }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
  </style>
</head>
<body>

  <!-- Top Market Indices Bar with MarketWatch Links -->
  <div class="indices-strip">
    % for my $idx (@$indices) {
      <a href="<%= $idx->{url} %>" target="_blank" rel="noopener noreferrer" class="index-card" title="Open <%= $idx->{name} %> on MarketWatch">
        <div class="index-info">
          <div class="name">
            <%= $idx->{name} %>
            <span class="link-icon">↗</span>
          </div>
          <div class="symbol"><%= $idx->{symbol} %> &bull; MarketWatch</div>
        </div>
        <div class="index-metrics">
          <div class="index-price"><%= sprintf("%.2f", $idx->{price}) %></div>
          <div class="index-change <%= $idx->{change} >= 0 ? 'positive' : 'negative' %>">
            <%= sprintf("%+.2f (%+.2f%%)", $idx->{change}, $idx->{pct}) %>
          </div>
        </div>
      </a>
    % }
  </div>

  <!-- Header with Actions & Themes -->
  <div class="header">
    <div class="header-title-box">
      <img src="favicon.svg?v=20261116b" alt="Logo" class="header-logo">
      <h1>AI Trader</h1>
      <span class="tag-badge">Semi-Aggressive Posture</span>
      <span class="tag-badge">Spec <code><%= substr($git_commit, 0, 7) %></code></span>
    </div>
    <div class="header-actions">
      <button id="btnEvaluate" class="btn btn-evaluate" onclick="evaluateMarket()">
        <span>⚡ Evaluate the Market</span>
      </button>

      <!-- Theme Dropdown (Icon Only with Dropdown) -->
      <div class="theme-dropdown">
        <button id="btnThemeToggle" class="btn-theme icon-only" title="Theme Selection" type="button" aria-haspopup="true" aria-expanded="false">
          <span id="themeIcon">💻</span>
        </button>
        <div id="themeMenu" class="theme-menu">
          <button type="button" class="theme-menu-item" data-theme-val="light" onclick="selectThemeMode('light')">
            <span>☀️</span> Light
            <span class="check">✓</span>
          </button>
          <button type="button" class="theme-menu-item" data-theme-val="dark" onclick="selectThemeMode('dark')">
            <span>🌙</span> Dark
            <span class="check">✓</span>
          </button>
          <button type="button" class="theme-menu-item" data-theme-val="system" onclick="selectThemeMode('system')">
            <span>💻</span> System
            <span class="check">✓</span>
          </button>
        </div>
      </div>
    </div>
  </div>

  <!-- Primary NAV & Benchmark Cards -->
  <div class="grid">
    <div class="card">
      <div class="card-title">Total Portfolio NAV</div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{total_nav}) %></div>
      <div class="card-sub">Baseline Capital: $10,000.00</div>
    </div>
    <div class="card">
      <div class="card-title">Cash Reserve Floor</div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{cash}) %></div>
      <div class="card-sub"><%= sprintf("%.1f", ($nav->{cash} / ($nav->{total_nav} || 1)) * 100) %>% Allocation (Min: 10%)</div>
    </div>
    <div class="card">
      <div class="card-title">SPY Inception Price</div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{spy_price}) %></div>
      <div class="card-sub">Primary S&amp;P 500 Benchmark</div>
    </div>
    <div class="card">
      <div class="card-title">Alpha (vs SPY)</div>
      <div class="card-value <%= $nav->{alpha} >= 0 ? 'positive' : 'negative' %>">
        <%= sprintf("%+.2f", $nav->{alpha} * 100) %>%
      </div>
      <div class="card-sub">Portfolio ROI: <%= sprintf("%.2f", $nav->{portfolio_return} * 100) %>%</div>
    </div>
  </div>

  <!-- Posture & Trigger Architecture -->
  <div class="posture-banner">
    <div class="posture-item">
      <strong>Trading Cadence:</strong> Automated daily at morning/post-close + on-demand manual evaluation
    </div>
    <div class="posture-item">
      <strong>Entry Trigger:</strong> Actionable catalysts scoring &ge; 7/10 (AI Silicon, Power Grid, Macro Duration)
    </div>
    <div class="posture-item">
      <strong>Exit Triggers:</strong> Hard Stop-Loss (-8.0%) &bull; Trailing Profit Lock (7.0% trail once &ge; +15.0% gain)
    </div>
    <div class="posture-item">
      <strong>Asset Universe:</strong> Equities, Sector ETFs, Fixed Income/Treasuries (<code>TLT</code>), Energy &amp; Thematic
    </div>
  </div>

  <!-- Active Positions -->
  <div class="section-title">
    <span>Open Portfolio Holdings</span>
    <span style="font-size: 0.8rem; font-weight: normal; color: var(--text-muted);"><%= scalar(@$positions) %> active position(s)</span>
  </div>
  <div class="table-container">
    <table>
      <thead>
        <tr>
          <th>Ticker</th>
          <th>Shares</th>
          <th>Cost Basis</th>
          <th>Market Price</th>
          <th>Market Value</th>
          <th>Return</th>
          <th>Sector / Asset Class</th>
          <th>High-Water Mark</th>
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
              <td><strong>$<%= sprintf("%.2f", $p->{market_val}) %></strong></td>
              <td class="<%= $p->{return_pct} >= 0 ? 'positive' : 'negative' %>"><%= sprintf("%+.2f", $p->{return_pct}) %>%</td>
              <td><%= $p->{sector} // 'General' %></td>
              <td>$<%= sprintf("%.2f", $p->{high_water_mark} // $p->{cost_basis}) %></td>
            </tr>
          % }
        % } else {
          <tr>
            <td colspan="8" style="text-align: center; color: var(--text-muted); padding: 24px;">
              No open positions. 100% Cash Allocation.
            </td>
          </tr>
        % }
      </tbody>
    </table>
  </div>

  <!-- Scored Catalyst Pipeline -->
  <div class="section-title">
    <span>Ingested Catalyst Scoring Pipeline</span>
    <span style="font-size: 0.8rem; font-weight: normal; color: var(--text-muted);">Evaluated via Gemini REST API &amp; 1–10 Rubric</span>
  </div>
  <div class="table-container">
    <table>
      <thead>
        <tr>
          <th>Timestamp</th>
          <th>Ticker</th>
          <th>Score</th>
          <th>Theme</th>
          <th>Headline &amp; Strategic Context</th>
        </tr>
      </thead>
      <tbody>
        % if (@$catalysts) {
          % for my $c (@$catalysts) {
            <tr>
              <td style="color: var(--text-muted); font-size: 0.8rem; white-space: nowrap;"><%= $c->{timestamp} %></td>
              <td><strong><%= $c->{ticker} // '-' %></strong></td>
              <td>
                % my $s = $c->{score} // 0;
                <span class="score-badge <%= $s >= 7 ? 'score-high' : ($s >= 4 ? 'score-mid' : 'score-low') %>">
                  <%= $s ? "$s/10" : 'PENDING' %>
                </span>
              </td>
              <td style="white-space: nowrap;"><%= $c->{theme} // '-' %></td>
              <td>
                <div style="font-weight: 600;"><%= $c->{headline} %></div>
                % if ($c->{rationale}) {
                  <div style="font-size: 0.8rem; color: var(--text-muted); margin-top: 4px;"><%= $c->{rationale} %></div>
                % }
              </td>
            </tr>
          % }
        % } else {
          <tr>
            <td colspan="5" style="text-align: center; color: var(--text-muted); padding: 24px;">
              No catalyst events recorded in ledger.
            </td>
          </tr>
        % }
      </tbody>
    </table>
  </div>

  <!-- Historical Trades & Rationales -->
  <div class="section-title">
    <span>Trade History &amp; Decision Rationales</span>
    <span style="font-size: 0.8rem; font-weight: normal; color: var(--text-muted);">Deterministic Execution Ledger (Audit Log)</span>
  </div>
  <div class="table-container">
    <table>
      <thead>
        <tr>
          <th>Timestamp</th>
          <th>Ticker</th>
          <th>Action</th>
          <th>Shares</th>
          <th>Fill Price</th>
          <th>Total Cost</th>
          <th>Score</th>
          <th>Execution Rationale &amp; Mandate Citation</th>
        </tr>
      </thead>
      <tbody>
        % if (@$trades) {
          % for my $t (@$trades) {
            <tr>
              <td style="color: var(--text-muted); font-size: 0.8rem; white-space: nowrap;"><%= $t->{timestamp} %></td>
              <td><strong><%= $t->{ticker} %></strong></td>
              <td><span class="<%= $t->{action} eq 'BUY' ? 'action-buy' : 'action-sell' %>"><%= $t->{action} %></span></td>
              <td><%= $t->{shares} %></td>
              <td>$<%= sprintf("%.2f", $t->{fill_price}) %></td>
              <td><strong>$<%= sprintf("%.2f", $t->{total_amount}) %></strong></td>
              <td><%= $t->{catalyst_score} ? "$t->{catalyst_score}/10" : '-' %></td>
              <td><%= $t->{rationale} %></td>
            </tr>
          % }
        % } else {
          <tr>
            <td colspan="8" style="text-align: center; color: var(--text-muted); padding: 24px;">
              No simulated trades recorded.
            </td>
          </tr>
        % }
      </tbody>
    </table>
  </div>

  <div id="toast"></div>

  <script>
    // Theme Management (System / Light / Dark) matching other DeFaria web apps
    let currentThemeMode = 'system';

    function getSystemTheme() {
      return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }

    function setThemeMode(mode, save = true) {
      currentThemeMode = mode;
      let effectiveTheme = mode;
      if (mode === 'system') {
        effectiveTheme = getSystemTheme();
      }
      if (save) {
        try { localStorage.setItem('ai_trader_theme', mode); } catch (e) {}
      }

      document.documentElement.setAttribute('data-theme', effectiveTheme);

      const iconEl = document.getElementById('themeIcon');
      const btn = document.getElementById('btnThemeToggle');
      if (iconEl && btn) {
        if (mode === 'system') {
          iconEl.textContent = '💻';
          btn.title = `Theme: System (${effectiveTheme}) - Click to change`;
        } else if (mode === 'light') {
          iconEl.textContent = '☀️';
          btn.title = 'Theme: Light - Click to change';
        } else {
          iconEl.textContent = '🌙';
          btn.title = 'Theme: Dark - Click to change';
        }
      }

      document.querySelectorAll('.theme-menu-item').forEach(item => {
        if (item.getAttribute('data-theme-val') === mode) {
          item.classList.add('active');
        } else {
          item.classList.remove('active');
        }
      });
    }

    function selectThemeMode(mode) {
      setThemeMode(mode, true);
      closeThemeMenu();
    }

    function toggleThemeMenu() {
      const menu = document.getElementById('themeMenu');
      if (menu) menu.classList.toggle('active');
    }

    function closeThemeMenu() {
      const menu = document.getElementById('themeMenu');
      if (menu) menu.classList.remove('active');
    }

    document.getElementById('btnThemeToggle').addEventListener('click', (e) => {
      e.stopPropagation();
      toggleThemeMenu();
    });

    document.addEventListener('click', (e) => {
      const dropdown = document.querySelector('.theme-dropdown');
      if (dropdown && !dropdown.contains(e.target)) {
        closeThemeMenu();
      }
    });

    if (window.matchMedia) {
      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
        if (currentThemeMode === 'system') {
          setThemeMode('system', false);
        }
      });
    }

    // Evaluate the Market trigger
    function showToast(msg) {
      const toast = document.getElementById('toast');
      toast.textContent = msg;
      toast.style.display = 'block';
      setTimeout(() => { toast.style.display = 'none'; }, 4000);
    }

    async function evaluateMarket() {
      const btn = document.getElementById('btnEvaluate');
      const origText = btn.innerHTML;
      btn.disabled = true;
      btn.innerHTML = '<span>⏳ Evaluating Market...</span>';

      try {
        const endpoint = window.location.pathname.endsWith('/')
          ? window.location.pathname + 'api/evaluate'
          : window.location.pathname + '/api/evaluate';

        const res = await fetch(endpoint, { method: 'POST' });
        const data = await res.json();
        if (data.success) {
          showToast('Market evaluation completed! Reloading ledger...');
          setTimeout(() => { window.location.reload(); }, 1200);
        } else {
          showToast('Evaluation failed: ' + (data.message || 'Unknown error'));
          btn.disabled = false;
          btn.innerHTML = origText;
        }
      } catch (err) {
        showToast('Error communicating with AI Trader backend.');
        btn.disabled = false;
        btn.innerHTML = origText;
      }
    }

    // Initial theme load
    const savedTheme = localStorage.getItem('ai_trader_theme') || 'system';
    setThemeMode(savedTheme, false);
  </script>

</body>
</html>
