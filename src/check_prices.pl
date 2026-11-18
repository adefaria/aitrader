#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Getopt::Long qw(:config no_ignore_case);
use Pod::Usage;
use POSIX qw(strftime tzset);
use Sys::Hostname qw(hostname);
use File::Path qw(make_path);
use Mojo::JSON qw(encode_json);
use Trader::DB qw(
    get_dbh init_schema get_latest_nav get_positions
    fetch_market_quote fetch_market_indices
    upsert_position record_nav record_run_log
);

eval {
    require Dotenv;
    Dotenv->load("$RealBin/../.env") if -f "$RealBin/../.env";
};

$| = 1;

my $threshold     = $ENV{ALERT_THRESHOLD_PCT} // 2.0;
my $dashboard_url = $ENV{DASHBOARD_URL}       // 'https://defaria.com/aitrader/';
my $db_path       = $ENV{DB_PATH}             // "$RealBin/../data/paper_ledger.db";
my $benchmark     = $ENV{BENCHMARK_TICKER}    // 'SPY';
my $trigger       = (-t STDIN) ? 'cli' : 'cron';
my $force         = 0;
my $dry_run       = 0;
my $test_alert    = 0;
my $help          = 0;

GetOptions(
    'threshold=f'  => \$threshold,
    'url=s'        => \$dashboard_url,
    'db=s'         => \$db_path,
    'trigger=s'    => \$trigger,
    'force'        => \$force,
    'dry-run'      => \$dry_run,
    'test-alert'   => \$test_alert,
    'help|h'       => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

# Friendly spoken names for tickers and indices
my %SPOKEN_NAMES = (
    'DOW'     => ' the Dow Jones',
    'S&P 500' => ' the S and P 500',
    'NASDAQ'  => ' the Nasdaq',
    'DIS'     => 'Disney',
    'HD'      => 'Home Depot',
    'QQQ'     => 'Q Q Q',
    'MSFT'    => 'Microsoft',
    'NVDA'    => 'NVIDIA',
    'SBUX'    => 'Starbucks',
    'XLI'     => 'X L I Industrials',
    'SPY'     => 'S P Y',
    'UNH'     => 'UnitedHealth',
    'VTI'     => 'V T I Total Market',
    'VOO'     => 'V O O',
    'AVGO'    => 'Broadcom',
    'AAPL'    => 'Apple',
    'CEG'     => 'Constellation Energy',
    'VST'     => 'Vistra',
    'TLT'     => 'T L T Treasury Bonds',
    'BND'     => 'B N D Total Bond',
);

sub is_market_hours_et {
    local $ENV{TZ} = 'America/New_York';
    tzset();
    my ($sec, $min, $hour, $mday, $mon, $year, $wday) = localtime(time);
    my $et_str = sprintf("%04d-%02d-%02d %02d:%02d:%02d ET (wday=%d)",
        $year + 1900, $mon + 1, $mday, $hour, $min, $sec, $wday);
    delete $ENV{TZ};
    tzset();

    # Monday (1) through Friday (5)
    return (0, $et_str) if $wday < 1 || $wday > 5;

    my $mins_since_midnight = $hour * 60 + $min;
    # Market open 09:30 ET (570 mins) through 16:15 ET (975 mins, allowing 4:00 PM closing run)
    my $is_open = ($mins_since_midnight >= 570 && $mins_since_midnight <= 975) ? 1 : 0;
    return ($is_open, $et_str);
}

my ($in_hours, $et_now) = is_market_hours_et();
my $now_ts = strftime("%Y-%m-%d %H:%M:%S", localtime);
my $today  = strftime("%Y-%m-%d", localtime);
my $current_host = lc(hostname() // '');
my @log_lines;

if ($trigger eq 'cron' && !$force && $current_host =~ /earth/) {
    print "[check_prices] Staging server ($current_host) detected; skipping automated cron/timer execution.\n";
    exit 0;
}

sub log_print {
    my ($msg) = @_;
    print $msg;
    push @log_lines, $msg;
}

log_print("========================================================\n");
log_print("[$now_ts] AI TRADER — Hourly Market & Portfolio Price Monitor (trigger=$trigger)\n");
log_print("Local Time: $now_ts | Market Time: $et_now\n");
log_print(sprintf("Alert Threshold: +/-%.2f%% | Dashboard: %s\n", $threshold, $dashboard_url));
log_print("========================================================\n");

if (!$in_hours && !$force && !$test_alert) {
    print "[check_prices] Outside regular US trading hours (09:30–16:15 ET Mon–Fri). Use --force to override.\n";
    exit 0;
}

my $dbh = get_dbh($db_path);
init_schema($dbh);

# Load today's prior alert/price states
my $prior_rows = $dbh->selectall_hashref(
    "SELECT * FROM price_alert_state WHERE date = ?",
    'symbol',
    undef,
    $today
) // {};

my @alerts;

sub evaluate_item {
    my (%item) = @_;
    my $symbol     = $item{symbol};
    my $label      = $item{label} // $symbol;
    my $asset_type = $item{asset_type};
    my $price      = $item{price};
    my $prev_close = $item{previous_close} || $price;
    my $day_change = $item{day_change} // ($price - $prev_close);
    my $day_pct    = $item{day_pct}    // (($prev_close > 0) ? (($day_change / $prev_close) * 100) : 0.0);

    my $prior = $prior_rows->{$symbol};
    my $last_price = $prior ? $prior->{last_price} : $prev_close;
    my $hourly_pct = ($last_price && $last_price > 0)
        ? ((($price - $last_price) / $last_price) * 100)
        : $day_pct;

    if (!$dry_run) {
        $dbh->do(qq{
            INSERT INTO price_snapshots (
                timestamp, symbol, asset_type, price, previous_close,
                day_change, day_change_pct, hourly_change_pct
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        }, undef, $now_ts, $symbol, $asset_type, $price, $prev_close, $day_change, $day_pct, $hourly_pct);
    }

    my $triggered = 0;
    my $trigger_reason = '';

    if ($prior && defined $prior->{last_alert_price} && $prior->{last_alert_price} > 0) {
        my $since_alert_pct = (($price - $prior->{last_alert_price}) / $prior->{last_alert_price}) * 100;
        if (abs($since_alert_pct) >= $threshold) {
            $triggered = 1;
            $trigger_reason = sprintf("%+.2f%% since last alert (%+.2f%% today)", $since_alert_pct, $day_pct);
        } elsif (abs($hourly_pct) >= $threshold) {
            $triggered = 1;
            $trigger_reason = sprintf("%+.2f%% in the last hour (%+.2f%% today)", $hourly_pct, $day_pct);
        }
    } else {
        if (abs($day_pct) >= $threshold) {
            $triggered = 1;
            $trigger_reason = sprintf("%+.2f%% today", $day_pct);
        } elsif (abs($hourly_pct) >= $threshold) {
            $triggered = 1;
            $trigger_reason = sprintf("%+.2f%% in the last hour", $hourly_pct);
        }
    }

    my $new_alert_price = $triggered ? $price   : ($prior ? $prior->{last_alert_price} : undef);
    my $new_alert_pct   = $triggered ? $day_pct : ($prior ? $prior->{last_alert_pct}   : undef);

    if (!$dry_run) {
        $dbh->do(qq{
            INSERT INTO price_alert_state (date, symbol, last_price, last_alert_price, last_alert_pct, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(date, symbol) DO UPDATE SET
                last_price       = excluded.last_price,
                last_alert_price = excluded.last_alert_price,
                last_alert_pct   = excluded.last_alert_pct,
                updated_at       = excluded.updated_at
        }, undef, $today, $symbol, $price, $new_alert_price, $new_alert_pct, $now_ts);
    }

    log_print(sprintf("  [%s] %-8s | Price: \$%9.2f | Day: %+6.2f%% (%+8.2f) | Hourly: %+6.2f%%%s\n",
        $asset_type, $label, $price, $day_pct, $day_change, $hourly_pct,
        ($triggered ? "  <-- ALERT!" : "")));

    if ($triggered) {
        push @alerts, {
            symbol         => $symbol,
            label          => $label,
            asset_type     => $asset_type,
            price          => $price,
            day_change     => $day_change,
            day_pct        => $day_pct,
            hourly_pct     => $hourly_pct,
            trigger_reason => $trigger_reason,
        };
    }
}

# 1. Fetch & Evaluate Major Indices
log_print("\n--- [1/3] Checking Major Market Indices ---\n");
my $indices = fetch_market_indices() // [];
for my $idx (@$indices) {
    next unless $idx->{price} && $idx->{price} > 0;
    my $prev = $idx->{price} - ($idx->{change} // 0);
    evaluate_item(
        symbol         => $idx->{symbol},
        label          => $idx->{name},
        asset_type     => 'INDEX',
        price          => $idx->{price},
        previous_close => $prev,
        day_change     => $idx->{change},
        day_pct        => $idx->{pct},
    );
}

# 2. Fetch & Evaluate Owned Holdings
log_print("\n--- [2/3] Checking Owned Portfolio Holdings ---\n");
my $positions = get_positions($dbh);
my $positions_value = 0.0;

for my $pos (@$positions) {
    my $ticker = $pos->{ticker};
    my $quote  = fetch_market_quote($ticker);
    if (!$quote || !$quote->{price}) {
        warn "  [WARN] Could not fetch live quote for $ticker; using cost basis fallback.\n";
        $positions_value += $pos->{shares} * $pos->{cost_basis};
        next;
    }

    my $price = $quote->{price};
    $positions_value += $pos->{shares} * $price;

    # Advance High-Water Mark if price reached a new high
    my $hwm = $pos->{high_water_mark} // $pos->{cost_basis};
    if ($price > $hwm && !$dry_run) {
        upsert_position($dbh, $ticker, $pos->{shares}, $pos->{cost_basis}, $price, $pos->{sector});
    }

    evaluate_item(
        symbol         => $ticker,
        label          => $ticker,
        asset_type     => 'HOLDING',
        price          => $price,
        previous_close => $quote->{previous_close},
        day_change     => $quote->{change},
        day_pct        => $quote->{pct},
    );
}

# 3. Update Intraday Portfolio NAV
log_print("\n--- [3/3] Updating Portfolio NAV & Benchmark ---\n");
my $nav_info = get_latest_nav($dbh);
my $recorded_total_nav = 0.0;
if ($nav_info) {
    my $cash = $nav_info->{cash};
    my $new_total_nav = $cash + $positions_value;
    $recorded_total_nav = $new_total_nav;
    my $hwm = $nav_info->{high_water_mark} // $new_total_nav;
    $hwm = $new_total_nav if $new_total_nav > $hwm;
    my $new_drawdown = ($hwm > 0) ? (($hwm - $new_total_nav) / $hwm) : 0.0;
    my $starting_capital = $ENV{STARTING_CAPITAL} // 167876.21;
    my $portfolio_return = ($new_total_nav - $starting_capital) / $starting_capital;

    my $spy_quote = fetch_market_quote($benchmark);
    my $spy_price = ($spy_quote && $spy_quote->{price}) ? $spy_quote->{price} : $nav_info->{spy_price};
    my ($day0_spy) = $dbh->selectrow_array("SELECT spy_price FROM daily_nav ORDER BY date ASC LIMIT 1");
    $day0_spy //= $spy_price;
    my $spy_return = ($day0_spy > 0) ? (($spy_price - $day0_spy) / $day0_spy) : 0.0;
    my $alpha = $portfolio_return - $spy_return;

    if (!$dry_run) {
        record_nav(
            $dbh,
            date             => $today,
            cash             => $cash,
            positions_value  => $positions_value,
            total_nav        => $new_total_nav,
            spy_price        => $spy_price,
            portfolio_return => $portfolio_return,
            spy_return       => $spy_return,
            alpha            => $alpha,
            high_water_mark  => $hwm,
            drawdown         => $new_drawdown,
        );
    }
    log_print(sprintf("  Total NAV: \$%.2f | Holdings: \$%.2f | Cash: \$%.2f | ROI: %+.2f%% | Alpha: %+.2f%%\n",
        $new_total_nav, $positions_value, $cash, $portfolio_return * 100, $alpha * 100));
}

# If --test-alert was requested and no real >= threshold move occurred right now,
# synthesize an alert from the top mover so the user can test the dialog & voice alert.
if ($test_alert && !@alerts) {
    push @alerts, {
        symbol         => 'NVDA',
        label          => 'NVDA',
        asset_type     => 'HOLDING',
        price          => 153.14,
        day_change     => 3.85,
        day_pct        => 2.58,
        hourly_pct     => 2.58,
        trigger_reason => '+2.58% today (Test Alert)',
    };
}

if (@alerts) {
    dispatch_notification(\@alerts);
} else {
    log_print(sprintf("\n[check_prices] No indices or holdings moved >= %.2f%% this check.\n", $threshold));
}

if (!$dry_run) {
    my $holdings_count = scalar(@$positions);
    my $alerts_count   = scalar(@alerts);
    my $alert_tickers  = @alerts ? (" (" . join(", ", map { sprintf("%s %+.2f%%", $_->{label}, $_->{day_pct}) } @alerts) . ")") : "";
    my $summary_str    = sprintf("Checked %d indices & %d holdings; %d alert%s triggered%s",
        scalar(@$indices), $holdings_count, $alerts_count, ($alerts_count == 1 ? '' : 's'), $alert_tickers);

    record_run_log(
        $dbh,
        timestamp        => $now_ts,
        run_type         => 'price_check',
        trigger_source   => $trigger,
        summary          => $summary_str,
        alerts_count     => $alerts_count,
        holdings_checked => $holdings_count,
        total_nav        => $recorded_total_nav,
        details_json     => encode_json({
            indices  => $indices,
            alerts   => \@alerts,
        }),
    );

    my $logs_dir = "$RealBin/../logs";
    make_path($logs_dir) unless -d $logs_dir;
    if (open my $lfh, '>>:encoding(UTF-8)', "$logs_dir/cron.log") {
        print $lfh join('', @log_lines), "\n";
        close $lfh;
    }
}

$dbh->disconnect;

sub shell_quote {
    my ($s) = @_;
    $s //= '';
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub pango_escape {
    my ($s) = @_;
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}

sub dispatch_notification {
    my ($alert_list) = @_;
    my $n = scalar(@$alert_list);
    return if $n <= 0;

    my $title = sprintf("AI Trader: %d Price Alert%s (+/-%.1f%%)",
        $n, ($n > 1 ? 's' : ''), $threshold);

    my $dialog_text = sprintf(
        "<b>%d market %s moved more than %.1f%%:</b>\n\n",
        $n, ($n > 1 ? 'positions/indices' : 'position/index'), $threshold
    );

    my @spoken_parts;
    for my $a (@$alert_list) {
        my $color = ($a->{day_pct} >= 0) ? '#2ea043' : '#d93025';
        my $arrow_entity = ($a->{day_pct} >= 0) ? '&#9650;' : '&#9660;';
        my $dir_label = ($a->{day_pct} >= 0) ? 'UP' : 'DOWN';
        my $tag   = ($a->{asset_type} eq 'INDEX') ? 'Index' : 'Holding';
        my $lbl   = pango_escape($a->{label});
        my $rsn   = pango_escape($a->{trigger_reason});
        $dialog_text .= sprintf(
            "&#8226; <span foreground=\"%s\"><b>%s</b></span> <b>%s</b> (%s): <b>\$%.2f</b> &#8212; <span foreground=\"%s\"><b>%s %s</b></span>\n",
            $color, $arrow_entity, $lbl, $tag, $a->{price}, $color, $dir_label, $rsn
        );

        if (@spoken_parts < 4) {
            my $spoken_name = $SPOKEN_NAMES{$a->{label}} // $a->{label};
            my $dir = ($a->{day_pct} >= 0) ? 'up' : 'down';
            my $pct_abs = sprintf("%.1f", abs($a->{day_pct}));
            push @spoken_parts, sprintf("%s is %s %s percent at %.2f",
                $spoken_name, $dir, $pct_abs, $a->{price});
        }
    }
    $dialog_text =~ s/\s+$//;

    my $more_spoken = ($n > 4) ? sprintf(", and %d more", $n - 4) : "";
    my $spoken_text = sprintf(
        "AI Trader price alert: %s%s.",
        join(". ", @spoken_parts),
        $more_spoken
    );

    if ($dry_run) {
        print "\n[DRY RUN] Would dispatch notification:\n";
        print "  Title:  $title\n";
        print "  Spoken: $spoken_text\n";
        return;
    }

    my $q_title  = shell_quote($title);
    my $q_text   = shell_quote($dialog_text);
    my $q_url    = shell_quote($dashboard_url);
    my $q_spoken = shell_quote($spoken_text);

    # Shell snippet that pops up the Zenity dialog; clicking "Open AI Trader" (exit 0)
    # opens the AI Trader web page in the user's browser, while "Dismiss" or closing exits cleanly.
    my $desktop_cmd =
        "export DISPLAY=:0 " .
        "XAUTHORITY=/home/andrew/.Xauthority " .
        "GSK_RENDERER=cairo " .
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; " .
        "if command -v zenity >/dev/null 2>&1; then " .
        "  ( if zenity --info --title=$q_title --text=$q_text --ok-label='Open AI Trader' --extra-button='Dismiss' --width=520 >/dev/null 2>&1; then " .
        "      xdg-open $q_url >/dev/null 2>&1 & " .
        "    fi ) >/dev/null 2>&1 & " .
        "elif command -v notify-send >/dev/null 2>&1; then " .
        "  notify-send -a 'AI Trader' -u critical -t 0 $q_title $q_spoken >/dev/null 2>&1; " .
        "fi; " .
        "if command -v speak >/dev/null 2>&1; then " .
        "  nohup speak -app 'AI Trader' $q_spoken >/dev/null 2>&1 & " .
        "elif [ -x /usr/local/bin/speak ]; then " .
        "  nohup /usr/local/bin/speak -app 'AI Trader' $q_spoken >/dev/null 2>&1 & " .
        "fi";

    my $host = lc(hostname() // '');
    if ($host =~ /cloud/ || $host eq 'defaria.com' || $host eq 'defaria') {
        my $rc = system('ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'earth', $desktop_cmd);
        if ($rc == 0) {
            print "\n[check_prices] Dispatched desktop & voice alert to earth via reverse SSH tunnel.\n";
        } else {
            warn "\n[check_prices] WARNING: Failed to dispatch remote desktop notification (rc=$rc).\n";
        }
    } else {
        system('bash', '-c', $desktop_cmd);
        print "\n[check_prices] Dispatched desktop & voice alert locally on $host.\n";
    }
}

__END__

=head1 NAME

check_prices.pl - Hourly trading-hours price monitor & +/-2% desktop/voice alert dispatcher

=head1 SYNOPSIS

check_prices.pl [options]

 Options:
   --threshold=PCT   Alert threshold percentage (default: 2.0)
   --url=URL         Dashboard URL opened when clicking dialog (default: https://defaria.com/aitrader/)
   --force           Run even outside regular US market trading hours
   --test-alert      Force a test desktop dialog and voice alert
   --dry-run         Fetch prices without updating DB or sending alerts
   --db=PATH         Path to SQLite database (default: data/paper_ledger.db)
   --help, -h        Show this help message

=cut
