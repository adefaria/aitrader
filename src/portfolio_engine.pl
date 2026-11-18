#!/usr/bin/env perl
use strict;
use warnings;
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Getopt::Long qw(:config no_ignore_case);
use Pod::Usage;
use POSIX qw(strftime floor);
use Mojo::JSON qw(encode_json);
use Trader::DB qw(
    get_dbh get_latest_nav get_positions fetch_market_price
    record_trade record_nav get_actionable_catalysts upsert_position close_position
    save_proposed_trades
);

eval {
    require Dotenv;
    Dotenv->load if -f '.env';
};

my $dry_run = 0;
my $propose = 0;
my $help    = 0;
my $db_path = $ENV{DB_PATH} // "$RealBin/../data/paper_ledger.db";
my $benchmark = $ENV{BENCHMARK_TICKER} // 'SPY';
my $exec_mode = $ENV{EXECUTION_MODE} // 'ADVISOR_BRIEF';

GetOptions(
    'dry-run' => \$dry_run,
    'propose' => \$propose,
    'db=s'    => \$db_path,
    'help|h'  => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

# In ADVISOR_BRIEF mode, trades are strictly proposed as recommendations for Jon (never auto-executed)
$propose = 1 if uc($exec_mode) eq 'ADVISOR_BRIEF';

print "[portfolio_engine] Evaluating risk management & portfolio execution constraints...\n";

my $dbh = get_dbh($db_path);
my $nav_info = get_latest_nav($dbh);

if (!$nav_info) {
    die "[portfolio_engine] ERROR: No NAV record found in $db_path. Please run init_db.pl first.\n";
}

my $cash      = $nav_info->{cash};
my $total_nav = $nav_info->{total_nav};
my $drawdown  = $nav_info->{drawdown} // 0.0;
my $today     = strftime("%Y-%m-%d", localtime);

printf "[portfolio_engine] Current NAV: \$%.2f | Cash: \$%.2f (%.1f%%) | Drawdown: %.1f%%\n",
    $total_nav, $cash, ($cash / $total_nav) * 100, $drawdown * 100;

# Circuit Breaker Check (specs/02-risk-management.md: Max Drawdown >= 12%)
my $buys_halted = 0;
if ($drawdown >= 0.12) {
    warn "[portfolio_engine] ALERT: Circuit breaker active (Drawdown >= 12%). All new BUY orders halted.\n";
    $buys_halted = 1;
}

# --- STEP 1: EVALUATE EXITS ON OPEN POSITIONS ---
my $positions = get_positions($dbh);
my %existing_tickers = map { $_->{ticker} => $_ } @$positions;
my %sector_values;
my @proposed_trades;

for my $pos (@$positions) {
    my $current_price = fetch_market_price($pos->{ticker}) // $pos->{cost_basis};
    my $cost_basis    = $pos->{cost_basis};
    my $hwm           = $pos->{high_water_mark} // $cost_basis;
    $hwm = $current_price if $current_price > $hwm;

    my $pct_change = (($current_price - $cost_basis) / $cost_basis) * 100;
    my $market_val = $pos->{shares} * $current_price;
    my $sector     = $pos->{sector} // 'General';
    $sector_values{$sector} += $market_val;

    printf "  - Open: %s | %d shs @ \$%.2f (Cur: \$%.2f, Return: %+.2f%%)\n",
        $pos->{ticker}, $pos->{shares}, $cost_basis, $current_price, $pct_change;

    my $exit_triggered = 0;
    my $exit_reason    = '';

    # Hard Stop-Loss check (specs/00-investor-profile.md & specs/02-risk-management.md: -10.0%)
    if ($pct_change <= -10.0) {
        $exit_triggered = 1;
        $exit_reason = sprintf("Hard stop-loss triggered (%.2f%% <= -10.0%%)", $pct_change);
    }
    # Trailing Profit Lock check (Once gain >= 12%, stop trails at 6% below high-water mark)
    elsif ($hwm >= $cost_basis * 1.12) {
        my $trail_threshold = $hwm * 0.94;
        if ($current_price <= $trail_threshold) {
            $exit_triggered = 1;
            $exit_reason = sprintf("Trailing profit lock triggered (\$%.2f <= \$%.2f trail threshold)", $current_price, $trail_threshold);
        }
    }

    if ($exit_triggered) {
        printf "    [EXIT ORDER] %s: %s\n", $pos->{ticker}, $exit_reason;
        my $proceeds = $pos->{shares} * $current_price;
        if ($propose) {
            push @proposed_trades, {
                ticker         => $pos->{ticker},
                action         => 'SELL',
                shares         => $pos->{shares} + 0,
                price          => sprintf("%.2f", $current_price) + 0,
                total_amount   => sprintf("%.2f", $proceeds) + 0,
                sector         => $sector,
                catalyst_score => undef,
                rationale      => $exit_reason,
            };
            $cash += $proceeds;
            delete $existing_tickers{$pos->{ticker}};
            $sector_values{$sector} -= $market_val;
        } elsif (!$dry_run) {
            record_trade(
                $dbh,
                ticker         => $pos->{ticker},
                action         => 'SELL',
                shares         => $pos->{shares},
                fill_price     => $current_price,
                total_amount   => $proceeds,
                catalyst_score => undef,
                rationale      => $exit_reason
            );
            close_position($dbh, $pos->{ticker});
            $cash += $proceeds;
            delete $existing_tickers{$pos->{ticker}};
            $sector_values{$sector} -= $market_val;
        }
    } else {
        # Update high-water mark if advanced
        if (!$dry_run && $hwm > ($pos->{high_water_mark} // 0)) {
            upsert_position($dbh, $pos->{ticker}, $pos->{shares}, $pos->{cost_basis}, $hwm, $sector);
        }
    }
}

# --- STEP 2: EVALUATE CATALYST CANDIDATES & ALLOCATE ---
if (!$buys_halted) {
    my $actionable = get_actionable_catalysts($dbh, 7);
    print "[portfolio_engine] Evaluating " . scalar(@$actionable) . " actionable catalyst candidate(s) (Score >= 7)...\n";

    # Sector mapping helper
    my %sector_map = (
        'NVDA' => 'Semiconductors & Compute',
        'AVGO' => 'Semiconductors & Compute',
        'MSFT' => 'Enterprise Software & AI Cloud',
        'AAPL' => 'Consumer Tech & Ecosystem',
        'VOO'  => 'Broad Market Index Funds',
        'SPY'  => 'Broad Market Index Funds',
        'VTI'  => 'Broad Market Index Funds',
        'QQQ'  => 'Large-Cap Tech Index Funds',
        'XLI'  => 'Industrial Sector ETF',
        'DIS'  => 'Communication Services & Media',
        'HD'   => 'Consumer Cyclical & Retail',
        'SBUX' => 'Consumer Cyclical & Retail',
        'UNH'  => 'Healthcare & Managed Care',
        'CEG'  => 'Power & Grid Utilities',
        'VST'  => 'Power & Grid Utilities',
        'ETN'  => 'Electrical Equipment',
        'TLT'  => 'Macro / Fixed Income & Bonds',
        'BND'  => 'Macro / Fixed Income & Bonds',
    );

    for my $cat (@$actionable) {
        my $ticker = $cat->{ticker};
        next unless $ticker;

        # Skip if position already held
        if ($existing_tickers{$ticker}) {
            printf "  - [%s] Position already open (%d shares). Skipping duplicate entry.\n",
                $ticker, $existing_tickers{$ticker}{shares};
            next;
        }

        my $score  = $cat->{score};
        my $sector = $sector_map{$ticker} // 'General Equities';

        # Verify universe eligibility: Price >= $5.00
        my $price = fetch_market_price($ticker);
        if (!defined $price || $price < 5.00) {
            warn "  - [$ticker] Excluded: Share price undefined or < \$5.00 (Penny stock rule).\n";
            next;
        }

        # Sizing limits (specs/00-investor-profile.md & specs/02-risk-management.md)
        my $max_pos_cap    = $total_nav * 0.25; # 25% max single-position ($2,500 on $10k)
        my $min_cash_floor = ($score >= 8) ? ($total_nav * 0.05) : ($total_nav * 0.08); # 8% cash buffer (5% for high conviction >= 8)
        my $max_sector_cap = $total_nav * 0.50; # 50% sector cap

        # Target sizing weights from investor profile
        my %target_weights = (
            'VOO'  => 0.20,
            'QQQ'  => 0.20,
            'VTI'  => 0.20,
            'NVDA' => 0.15,
            'MSFT' => 0.15,
            'AVGO' => 0.15,
            'AAPL' => 0.15,
            'VST'  => 0.15,
            'CEG'  => 0.15,
            'TLT'  => 0.10,
            'BND'  => 0.10,
        );
        my $target_weight = $target_weights{$ticker} // 0.15;
        my $ideal_alloc   = $total_nav * $target_weight;

        my $current_sector_val = $sector_values{$sector} // 0.0;
        my $avail_sector_room  = $max_sector_cap - $current_sector_val;
        my $avail_cash         = $cash - $min_cash_floor;

        my $target_alloc = $ideal_alloc;
        $target_alloc = $max_pos_cap if $target_alloc > $max_pos_cap;
        $target_alloc = $avail_cash if $avail_cash < $target_alloc;
        $target_alloc = $avail_sector_room if $avail_sector_room < $target_alloc;

        if ($target_alloc <= $price) {
            printf "  - [%s] Insufficient allocation room (\$%.2f) for 1 share @ \$%.2f. Cash: \$%.2f, Cash Floor: \$%.2f\n",
                $ticker, $target_alloc, $price, $cash, $min_cash_floor;
            next;
        }

        my $shares = floor($target_alloc / $price);
        my $total_cost = $shares * $price;

        printf "  - [BUY ORDER CANDIDATE] %s (%s): %d shares @ \$%.2f = \$%.2f (Score: %d/10)\n",
            $ticker, $sector, $shares, $price, $total_cost, $score;

        my $trade_rationale = sprintf("Score %d/10 catalyst: %s", $score, $cat->{rationale} // $cat->{headline});

        if ($propose) {
            push @proposed_trades, {
                ticker         => $ticker,
                action         => 'BUY',
                shares         => $shares + 0,
                price          => sprintf("%.2f", $price) + 0,
                total_amount   => sprintf("%.2f", $total_cost) + 0,
                sector         => $sector,
                catalyst_score => $score + 0,
                rationale      => $trade_rationale,
            };
            $cash -= $total_cost;
            $sector_values{$sector} += $total_cost;
            $existing_tickers{$ticker} = { shares => $shares, cost_basis => $price };
        } elsif (!$dry_run) {
            record_trade(
                $dbh,
                ticker         => $ticker,
                action         => 'BUY',
                shares         => $shares,
                fill_price     => $price,
                total_amount   => $total_cost,
                catalyst_score => $score,
                rationale      => $trade_rationale
            );
            upsert_position($dbh, $ticker, $shares, $price, $price, $sector);
            $cash -= $total_cost;
            $sector_values{$sector} += $total_cost;
            $existing_tickers{$ticker} = { shares => $shares, cost_basis => $price };
            printf "    -> FILLED: %s position opened. Remaining cash: \$%.2f\n", $ticker, $cash;
        }
    }
}

# --- STEP 3: UPDATE DAILY NAV & BENCHMARK ALPHA ---
my $actual_cash = $propose ? $nav_info->{cash} : $cash;
my $updated_positions = get_positions($dbh);
my $positions_value = 0.0;
for my $p (@$updated_positions) {
    my $mkt = fetch_market_price($p->{ticker}) // $p->{cost_basis};
    $positions_value += $p->{shares} * $mkt;
}

my $new_total_nav = $actual_cash + $positions_value;
my $hwm = $nav_info->{high_water_mark} // $total_nav;
$hwm = $new_total_nav if $new_total_nav > $hwm;
my $new_drawdown = ($hwm > 0) ? (($hwm - $new_total_nav) / $hwm) : 0.0;

my $starting_capital = $ENV{STARTING_CAPITAL} // 167876.21;
my $portfolio_return = ($new_total_nav - $starting_capital) / $starting_capital;

my $spy_price = fetch_market_price($benchmark) // $nav_info->{spy_price};
# Calculate SPY return from Day 0
my ($day0_spy) = $dbh->selectrow_array("SELECT spy_price FROM daily_nav ORDER BY date ASC LIMIT 1");
$day0_spy //= $spy_price;
my $spy_return = ($day0_spy > 0) ? (($spy_price - $day0_spy) / $day0_spy) : 0.0;
my $alpha = $portfolio_return - $spy_return;

if (!$dry_run) {
    record_nav(
        $dbh,
        date             => $today,
        cash             => $actual_cash,
        positions_value  => $positions_value,
        total_nav        => $new_total_nav,
        spy_price        => $spy_price,
        portfolio_return => $portfolio_return,
        spy_return       => $spy_return,
        alpha            => $alpha,
        high_water_mark  => $hwm,
        drawdown         => $new_drawdown
    );
    printf "[portfolio_engine] Ledger updated: Total NAV: \$%.2f | Cash: \$%.2f (%.1f%%) | Alpha: %+.2f%%\n",
        $new_total_nav, $actual_cash, ($actual_cash / $new_total_nav) * 100, $alpha * 100;
} else {
    printf "[portfolio_engine] [DRY RUN] Projected NAV: \$%.2f | Projected Cash: \$%.2f (%.1f%%)\n",
        $new_total_nav, $actual_cash, ($actual_cash / $new_total_nav) * 100;
}

if ($propose) {
    save_proposed_trades($dbh, \@proposed_trades) if !$dry_run;
    print "__PROPOSED_TRADES_JSON__:" . encode_json(\@proposed_trades) . "\n";
}

$dbh->disconnect;

__END__

=head1 NAME

portfolio_engine.pl - Enforce risk management, position sizing, and stop-loss logic

=head1 SYNOPSIS

portfolio_engine.pl [options]

 Options:
   --dry-run       Verify risk calculations without executing trades
   --db=PATH       Path to SQLite database
   --help, -h      Show this help message

=cut
