#!/usr/bin/env perl
use strict;
use warnings;
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Mojolicious::Lite -signatures;
use Mojo::JSON qw(decode_json encode_json true false);
use POSIX qw(strftime);
use File::Spec;
use Trader::DB qw(
    get_dbh get_latest_nav get_positions fetch_market_price
    fetch_market_indices get_git_commit record_trade record_nav
    upsert_position close_position
);

eval {
    require Dotenv;
    Dotenv->load if -f '.env';
};

# Override Mojolicious default static extra (which otherwise intercepts /favicon.ico with the default mojo icon)
delete app->static->extra->{'favicon.ico'};
app->static->extra->{'favicon.ico'} = "$RealBin/../public/favicon.ico";
unshift @{app->static->paths}, "$RealBin/../public";

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

get '/api/history' => sub ($c) {
    my $dbh = $c->db;
    my $rows = $dbh->selectall_arrayref(
        "SELECT date, cash, positions_value, total_nav, spy_price, portfolio_return, spy_return, alpha, high_water_mark, drawdown FROM daily_nav ORDER BY date ASC",
        { Slice => {} }
    );
    $dbh->disconnect;

    $c->render(json => {
        success => 1,
        history => $rows,
    });
};

sub _write_eval_status ($path, $data) {
    my $tmp = "$path.tmp.$$";
    if (open my $fh, '>', $tmp) {
        binmode $fh, ':encoding(UTF-8)';
        print $fh encode_json($data);
        close $fh;
        rename $tmp, $path;
    }
}

post '/api/evaluate/start' => sub ($c) {
    my $job_id = time() . '_' . $$ . '_' . int(rand(100000));
    my $status_file = File::Spec->catfile(File::Spec->tmpdir(), "aitrader_eval_$job_id.json");

    my $state = {
        job_id          => $job_id,
        step            => 0,
        total_steps     => 5,
        percent         => 5,
        label           => 'Initializing market evaluation...',
        log             => '',
        done            => false,
        success         => false,
        proposed_trades => [],
    };
    _write_eval_status($status_file, $state);

    my $pid = fork();
    if (!defined $pid) {
        return $c->render(status => 500, json => {
            success => 0,
            message => "Failed to spawn evaluation worker: $!",
        });
    }

    if ($pid == 0) {
        # Child worker process: restore default SIGCHLD so close($fh) captures exit code properly
        $SIG{CHLD} = 'DEFAULT';
        my $cmd = "perl -Ilocal/lib/perl5 -I$RealBin/lib $RealBin/run_daily.pl --propose 2>&1";
        if (open my $fh, '-|:encoding(UTF-8)', $cmd) {
            while (my $line = <$fh>) {
                if ($line =~ /^__PROPOSED_TRADES_JSON__:(.*)$/) {
                    my $json_str = $1;
                    my $parsed = eval { decode_json($json_str) };
                    $state->{proposed_trades} = $parsed if ref $parsed eq 'ARRAY';
                    next;
                }
                $state->{log} .= $line;
                if ($line =~ /\[Step\s+(\d+)\/(\d+)\]\s*(.+?)\s*-*\s*$/) {
                    my ($s, $tot, $lbl) = ($1 + 0, $2 + 0, $3);
                    $state->{step} = $s;
                    $state->{total_steps} = $tot;
                    $state->{percent} = int(($s / $tot) * 85) + 5;
                    $state->{label} = "Step $s/$tot: $lbl";
                } elsif ($line =~ /\[evaluate_catalysts\]\s+Evaluating/) {
                    $state->{percent} = 78;
                } elsif ($line =~ /\[portfolio_engine\]\s+Evaluating/) {
                    $state->{percent} = 90;
                }
                _write_eval_status($status_file, $state);
            }
            close $fh;
            my $exit_code = ($? == -1) ? 0 : ($? >> 8);
            my $ok = ($exit_code == 0 || $state->{log} =~ /verification SUCCESSFUL!/) ? 1 : 0;
            $state->{done} = true;
            $state->{percent} = 100;
            if ($ok) {
                $state->{success} = true;
                $state->{label} = 'Market evaluation complete.';
            } else {
                $state->{success} = false;
                $state->{label} = "Market evaluation failed (exit code $exit_code).";
            }
        } else {
            $state->{done} = true;
            $state->{success} = false;
            $state->{percent} = 100;
            $state->{label} = "Failed to launch run_daily.pl: $!";
            $state->{log} .= "Error: $!\n";
        }
        _write_eval_status($status_file, $state);
        POSIX::_exit(0);
    }

    # Reap zombies non-blockingly when convenient
    $SIG{CHLD} = 'IGNORE';

    $c->render(json => {
        success => 1,
        job_id  => $job_id,
    });
};

get '/api/evaluate/status/:id' => sub ($c) {
    my $id = $c->param('id') // '';
    if ($id !~ /^[a-zA-Z0-9_]+$/) {
        return $c->render(status => 400, json => { success => 0, message => 'Invalid job ID.' });
    }
    my $status_file = File::Spec->catfile(File::Spec->tmpdir(), "aitrader_eval_$id.json");
    if (!-f $status_file) {
        return $c->render(status => 404, json => { success => 0, message => 'Evaluation job not found.' });
    }
    local $/;
    open my $fh, '<:encoding(UTF-8)', $status_file or return $c->render(status => 500, json => { success => 0, message => "Cannot read status: $!" });
    my $raw = <$fh>;
    close $fh;

    my $data = eval { decode_json($raw) };
    if (!$data) {
        return $c->render(status => 500, json => { success => 0, message => 'Invalid status payload.' });
    }

    if ($data->{done} && $data->{success}) {
        %PRICE_CACHE = ();
        $INDICES_CACHE = undef;
    }

    $c->render(json => $data);
};

post '/api/trades/execute' => sub ($c) {
    my $payload = $c->req->json;
    my $trades = ($payload && ref $payload->{trades} eq 'ARRAY') ? $payload->{trades} : [];

    if (!@$trades) {
        return $c->render(json => {
            success        => 1,
            executed_count => 0,
            message        => 'No trades selected for execution.',
        });
    }

    my $dbh = $c->db;
    my $nav_info = get_latest_nav($dbh);
    if (!$nav_info) {
        $dbh->disconnect;
        return $c->render(status => 400, json => {
            success => 0,
            message => 'Ledger not initialized. Run market evaluation first.',
        });
    }

    my $cash = $nav_info->{cash};
    my $positions = get_positions($dbh);
    my %pos_map = map { $_->{ticker} => $_ } @$positions;

    my $executed = 0;
    my @skipped;

    for my $t (@$trades) {
        my $ticker = uc($t->{ticker} // '');
        my $action = uc($t->{action} // '');
        my $shares = ($t->{shares} // 0) + 0;
        next unless $ticker && ($action eq 'BUY' || $action eq 'SELL') && $shares > 0;

        my $fill_price = fetch_market_price($ticker) // ($t->{price} + 0);
        if (!$fill_price || $fill_price <= 0) {
            push @skipped, "$ticker: unable to determine market price";
            next;
        }

        if ($action eq 'SELL') {
            my $pos = $pos_map{$ticker};
            if (!$pos || $pos->{shares} <= 0) {
                push @skipped, "$ticker: no open position to sell";
                next;
            }
            my $sell_shares = ($shares >= $pos->{shares}) ? $pos->{shares} : $shares;
            my $proceeds = $sell_shares * $fill_price;
            record_trade(
                $dbh,
                ticker         => $ticker,
                action         => 'SELL',
                shares         => $sell_shares,
                fill_price     => $fill_price,
                total_amount   => $proceeds,
                catalyst_score => $t->{catalyst_score},
                rationale      => $t->{rationale} // 'User-approved exit trade',
            );
            if ($sell_shares >= $pos->{shares}) {
                close_position($dbh, $ticker);
                delete $pos_map{$ticker};
            } else {
                my $rem = $pos->{shares} - $sell_shares;
                upsert_position($dbh, $ticker, $rem, $pos->{cost_basis}, $pos->{high_water_mark}, $pos->{sector});
                $pos->{shares} = $rem;
            }
            $cash += $proceeds;
            $executed++;
        } elsif ($action eq 'BUY') {
            my $total_cost = $shares * $fill_price;
            if ($total_cost > $cash) {
                push @skipped, sprintf("%s: insufficient cash (\$%.2f needed, \$%.2f available)", $ticker, $total_cost, $cash);
                next;
            }
            my $sector = $t->{sector} // 'General Equities';
            record_trade(
                $dbh,
                ticker         => $ticker,
                action         => 'BUY',
                shares         => $shares,
                fill_price     => $fill_price,
                total_amount   => $total_cost,
                catalyst_score => $t->{catalyst_score},
                rationale      => $t->{rationale} // 'User-approved entry trade',
            );
            if (my $existing = $pos_map{$ticker}) {
                my $new_shares = $existing->{shares} + $shares;
                my $new_basis  = (($existing->{shares} * $existing->{cost_basis}) + $total_cost) / $new_shares;
                my $hwm = ($fill_price > ($existing->{high_water_mark} // 0)) ? $fill_price : $existing->{high_water_mark};
                upsert_position($dbh, $ticker, $new_shares, $new_basis, $hwm, $sector);
                $existing->{shares} = $new_shares;
                $existing->{cost_basis} = $new_basis;
            } else {
                upsert_position($dbh, $ticker, $shares, $fill_price, $fill_price, $sector);
                $pos_map{$ticker} = { shares => $shares, cost_basis => $fill_price, high_water_mark => $fill_price, sector => $sector };
            }
            $cash -= $total_cost;
            $executed++;
        }
    }

    # Recompute daily_nav after trade execution
    my $updated_positions = get_positions($dbh);
    my $positions_value = 0.0;
    for my $p (@$updated_positions) {
        my $mkt = fetch_market_price($p->{ticker}) // $p->{cost_basis};
        $positions_value += $p->{shares} * $mkt;
    }
    my $new_total_nav = $cash + $positions_value;
    my $hwm = $nav_info->{high_water_mark} // $new_total_nav;
    $hwm = $new_total_nav if $new_total_nav > $hwm;
    my $new_drawdown = ($hwm > 0) ? (($hwm - $new_total_nav) / $hwm) : 0.0;
    my $starting_capital = $ENV{STARTING_CAPITAL} // 167876.21;
    my $portfolio_return = ($new_total_nav - $starting_capital) / $starting_capital;
    my $benchmark = $ENV{BENCHMARK_TICKER} // 'SPY';
    my $spy_price = fetch_market_price($benchmark) // $nav_info->{spy_price};
    my ($day0_spy) = $dbh->selectrow_array("SELECT spy_price FROM daily_nav ORDER BY date ASC LIMIT 1");
    $day0_spy //= $spy_price;
    my $spy_return = ($day0_spy > 0) ? (($spy_price - $day0_spy) / $day0_spy) : 0.0;
    my $alpha = $portfolio_return - $spy_return;
    my $today = strftime("%Y-%m-%d", localtime);

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

    $dbh->disconnect;
    %PRICE_CACHE = ();
    $INDICES_CACHE = undef;

    $c->render(json => {
        success        => 1,
        executed_count => $executed,
        skipped        => \@skipped,
        message        => "Executed $executed trade(s) successfully.",
    });
};

post '/api/evaluate' => sub ($c) {
    my $cmd = "perl -Ilocal/lib/perl5 -I$RealBin/lib $RealBin/run_daily.pl --propose 2>&1";
    my $output = `$cmd`;
    my $exit_code = $? >> 8;

    if ($exit_code == 0) {
        %PRICE_CACHE = ();
        $INDICES_CACHE = undef;
        $c->render(json => {
            success => 1,
            message => 'Market evaluation and advisor trade recommendations completed successfully.',
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
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2NCA2NCIgd2lkdGg9IjY0IiBoZWlnaHQ9IjY0Ij4KICA8c3R5bGU+CiAgICAuYmcgeyBmaWxsOiAjMDkwYzEwOyBzdHJva2U6IHJnYmEoMjU1LCAyNTUsIDI1NSwgMC4xNSk7IH0KICAgIC5jYW5kbGUtZ3JlZW4geyBmaWxsOiAjMmVhMDQzOyBzdHJva2U6ICMyZWEwNDM7IH0KICAgIC5jYW5kbGUtYmx1ZSB7IGZpbGw6ICMzODhiZmQ7IHN0cm9rZTogIzM4OGJmZDsgfQogICAgLmhhbG8geyBzdHJva2U6ICMwOTBjMTA7IGZpbGw6ICMwOTBjMTA7IH0KICAgIC5ncmFwaC1saW5lIHsgc3Ryb2tlOiAjMDBlNjc2OyBmaWxsOiAjMDBlNjc2OyB9CgogICAgQG1lZGlhIChwcmVmZXJzLWNvbG9yLXNjaGVtZTogbGlnaHQpIHsKICAgICAgLmJnIHsgZmlsbDogI2Y4ZmFmYzsgc3Ryb2tlOiAjY2JkNWUxOyB9CiAgICAgIC5jYW5kbGUtZ3JlZW4geyBmaWxsOiAjODZlZmFjOyBzdHJva2U6ICMyMmM1NWU7IH0KICAgICAgLmNhbmRsZS1ibHVlIHsgZmlsbDogIzkzYzVmZDsgc3Ryb2tlOiAjM2I4MmY2OyB9CiAgICAgIC5oYWxvIHsgc3Ryb2tlOiAjZjhmYWZjOyBmaWxsOiAjZjhmYWZjOyB9CiAgICAgIC5ncmFwaC1saW5lIHsgc3Ryb2tlOiAjMTZhMzRhOyBmaWxsOiAjMTZhMzRhOyB9CiAgICB9CiAgPC9zdHlsZT4KICA8cmVjdCB3aWR0aD0iNjQiIGhlaWdodD0iNjQiIHJ4PSIxNCIgY2xhc3M9ImJnIiBzdHJva2Utd2lkdGg9IjIiLz4KICA8bGluZSB4MT0iMTgiIHkxPSIxNCIgeDI9IjE4IiB5Mj0iNTAiIGNsYXNzPSJjYW5kbGUtZ3JlZW4iIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgPHJlY3QgeD0iMTQiIHk9IjI0IiB3aWR0aD0iOCIgaGVpZ2h0PSIyNCIgcng9IjIiIGNsYXNzPSJjYW5kbGUtZ3JlZW4iLz4KICA8bGluZSB4MT0iMzIiIHkxPSIxMCIgeDI9IjMyIiB5Mj0iNDQiIGNsYXNzPSJjYW5kbGUtYmx1ZSIgc3Ryb2tlLXdpZHRoPSIzIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICA8cmVjdCB4PSIyOCIgeT0iMTgiIHdpZHRoPSI4IiBoZWlnaHQ9IjIwIiByeD0iMiIgY2xhc3M9ImNhbmRsZS1ibHVlIi8+CiAgPGxpbmUgeDE9IjQ2IiB5MT0iMjAiIHgyPSI0NiIgeTI9IjU0IiBjbGFzcz0iY2FuZGxlLWdyZWVuIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogIDxyZWN0IHg9IjQyIiB5PSIyOCIgd2lkdGg9IjgiIGhlaWdodD0iMjAiIHJ4PSIyIiBjbGFzcz0iY2FuZGxlLWdyZWVuIi8+CiAgPHBhdGggZD0iTTExIDQ0IEwyNSAzMCBMMzcgMzYgTDUyIDE0IiBmaWxsPSJub25lIiBjbGFzcz0iaGFsbyIgc3Ryb2tlLXdpZHRoPSI3LjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPgogIDxjaXJjbGUgY3g9IjUyIiBjeT0iMTQiIHI9IjYuNSIgY2xhc3M9ImhhbG8iLz4KICA8cGF0aCBkPSJNMTEgNDQgTDI1IDMwIEwzNyAzNiBMNTIgMTQiIGZpbGw9Im5vbmUiIGNsYXNzPSJncmFwaC1saW5lIiBzdHJva2Utd2lkdGg9IjQuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+CiAgPGNpcmNsZSBjeD0iNTIiIGN5PSIxNCIgcj0iNC41IiBjbGFzcz0iZ3JhcGgtbGluZSIvPgo8L3N2Zz4=">
  <link rel="icon" type="image/svg+xml" href="favicon.svg?v=20261116c">
  <link rel="icon" type="image/png" sizes="32x32" href="favicon-32x32.png?v=20261116c">
  <link rel="icon" type="image/png" sizes="16x16" href="favicon-16x16.png?v=20261116c">
  <link rel="apple-touch-icon" sizes="180x180" href="apple-touch-icon.png?v=20261116c">
  <link rel="shortcut icon" href="favicon.ico?v=20261116c">
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
    .clickable-card {
      cursor: pointer;
      transition: transform 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease;
    }
    .clickable-card:hover {
      transform: translateY(-2px);
      border-color: var(--accent-primary);
      box-shadow: 0 6px 16px rgba(0, 0, 0, 0.25);
    }
    .card-title { font-size: 0.8rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 6px; font-weight: 600; display: flex; justify-content: space-between; align-items: center; gap: 8px; }
    .card-chart-hint {
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: none;
      letter-spacing: 0;
      color: var(--text-muted);
      background: var(--card-inner);
      border: 1px solid var(--border);
      border-radius: 999px;
      padding: 2px 8px;
      display: inline-flex;
      align-items: center;
      gap: 4px;
      transition: all 0.15s ease;
    }
    .clickable-card:hover .card-chart-hint {
      color: var(--accent-primary);
      border-color: var(--accent-primary);
      background: var(--accent-hover);
    }
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
    .catalyst-link {
      color: var(--text);
      text-decoration: none;
      font-weight: 600;
      transition: color 0.15s ease;
      display: inline-block;
    }
    .catalyst-link:hover {
      color: var(--accent-primary);
      text-decoration: underline;
    }
    .catalyst-link .external-icon {
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-left: 4px;
      vertical-align: middle;
      opacity: 0.8;
    }
    .catalyst-link:hover .external-icon {
      color: var(--accent-primary);
      opacity: 1;
    }

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

    /* Modal Dialogs */
    .modal-backdrop {
      display: none;
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.68);
      backdrop-filter: blur(3px);
      z-index: 2000;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .modal-backdrop.active { display: flex; }
    .modal-dialog {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 12px;
      width: 100%;
      max-width: 820px;
      max-height: 90vh;
      display: flex;
      flex-direction: column;
      box-shadow: 0 20px 50px rgba(0, 0, 0, 0.55);
      overflow: hidden;
      animation: fadeIn 0.2s ease;
    }
    .modal-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 16px 20px;
      border-bottom: 1px solid var(--border);
      background: var(--card-inner);
    }
    .modal-title { font-size: 1.1rem; font-weight: 700; display: flex; align-items: center; gap: 8px; }
    .modal-close {
      background: transparent;
      border: 1px solid transparent;
      color: var(--text-muted);
      font-size: 1.4rem;
      line-height: 1;
      width: 32px;
      height: 32px;
      border-radius: 6px;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }
    .modal-close:hover { background: var(--accent-hover); color: var(--text); border-color: var(--border); }
    .modal-body { padding: 20px; overflow-y: auto; flex: 1; }
    .modal-footer {
      padding: 14px 20px;
      border-top: 1px solid var(--border);
      background: var(--card-inner);
      display: flex;
      justify-content: flex-end;
      align-items: center;
      gap: 10px;
    }

    /* Metric Chart Modal */
    .metric-tabs {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-bottom: 16px;
    }
    .metric-tab {
      padding: 6px 12px;
      border-radius: 6px;
      font-size: 0.8rem;
      font-weight: 600;
      background: var(--card-inner);
      color: var(--text-muted);
      border: 1px solid var(--border);
      cursor: pointer;
      transition: all 0.15s ease;
    }
    .metric-tab:hover { color: var(--text); border-color: var(--accent-primary); }
    .metric-tab.active { background: var(--accent-primary); color: #ffffff; border-color: var(--accent-primary); }
    .chart-stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
      gap: 10px;
      margin-bottom: 16px;
    }
    .chart-stat-box {
      background: var(--card-inner);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 8px 12px;
    }
    .chart-stat-label { font-size: 0.7rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.4px; }
    .chart-stat-val { font-size: 1rem; font-weight: 700; font-family: monospace; margin-top: 2px; }
    .chart-wrap {
      position: relative;
      background: var(--card-inner);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 12px;
    }
    .chart-tooltip {
      display: none;
      position: absolute;
      pointer-events: none;
      background: var(--card-bg);
      border: 1px solid var(--accent-primary);
      border-radius: 6px;
      padding: 6px 10px;
      font-size: 0.78rem;
      box-shadow: var(--shadow);
      z-index: 10;
      white-space: nowrap;
    }

    /* Progress Bar & Evaluation Dialog */
    .eval-progress-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 0.88rem;
      font-weight: 600;
      margin-bottom: 8px;
    }
    .progress-track {
      width: 100%;
      height: 12px;
      background: var(--card-inner);
      border: 1px solid var(--border);
      border-radius: 999px;
      overflow: hidden;
      margin-bottom: 14px;
    }
    .progress-fill {
      height: 100%;
      width: 0%;
      background: linear-gradient(90deg, var(--accent-primary), var(--success));
      border-radius: 999px;
      transition: width 0.35s ease;
    }
    .eval-log-toggle {
      font-size: 0.78rem;
      color: var(--accent-primary);
      background: none;
      border: none;
      cursor: pointer;
      padding: 0;
      margin-bottom: 8px;
      font-weight: 600;
    }
    .eval-log {
      display: none;
      background: var(--accent-black);
      color: #c9d1d9;
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 10px 12px;
      font-family: monospace;
      font-size: 0.75rem;
      max-height: 170px;
      overflow-y: auto;
      white-space: pre-wrap;
      margin-bottom: 16px;
    }
    .eval-log.open { display: block; }
    .suggested-trades-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin: 12px 0 10px;
      font-weight: 700;
      font-size: 0.95rem;
    }
    .eval-empty-box {
      background: var(--card-inner);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 16px;
      text-align: center;
      color: var(--text-muted);
      font-size: 0.88rem;
    }

    /* Toggle Switch */
    .toggle-switch {
      position: relative;
      display: inline-block;
      width: 42px;
      height: 22px;
    }
    .toggle-switch input { opacity: 0; width: 0; height: 0; }
    .toggle-slider {
      position: absolute;
      cursor: pointer;
      inset: 0;
      background-color: var(--border);
      transition: 0.2s;
      border-radius: 22px;
    }
    .toggle-slider:before {
      position: absolute;
      content: "";
      height: 16px;
      width: 16px;
      left: 3px;
      bottom: 3px;
      background-color: #ffffff;
      transition: 0.2s;
      border-radius: 50%;
    }
    .toggle-switch input:checked + .toggle-slider { background-color: var(--success); }
    .toggle-switch input:checked + .toggle-slider:before { transform: translateX(20px); }

    .btn-primary {
      background: var(--accent-primary);
      color: #ffffff;
      border-color: var(--accent-primary);
    }
    .btn-primary:hover { opacity: 0.92; }
    .btn-secondary {
      background: var(--card-bg);
      color: var(--text);
      border-color: var(--border);
    }
    .btn-secondary:hover { background: var(--accent-hover); }
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
      <img src="favicon.svg?v=20261116c" alt="Logo" class="header-logo">
      <h1>AI Trader</h1>
      <span class="tag-badge">Advisor Recommendations Mode (with Jon)</span>
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
    <div class="card clickable-card" role="button" tabindex="0" onclick="openMetricModal('total_nav')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();openMetricModal('total_nav');}" title="Click to open Total Portfolio NAV chart dialog">
      <div class="card-title">
        <span>Total Portfolio NAV</span>
        <span class="card-chart-hint">📈 Chart</span>
      </div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{total_nav}) %></div>
      <div class="card-sub">Invested Capital: $167,876.21 ($159,132.64 Eq + $8,743.57 Cash)</div>
    </div>
    <div class="card clickable-card" role="button" tabindex="0" onclick="openMetricModal('cash')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();openMetricModal('cash');}" title="Click to open Cash Reserve Floor chart dialog">
      <div class="card-title">
        <span>Cash Reserve Floor</span>
        <span class="card-chart-hint">📈 Chart</span>
      </div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{cash}) %></div>
      <div class="card-sub"><%= sprintf("%.1f", ($nav->{cash} / ($nav->{total_nav} || 1)) * 100) %>% Allocation (Min: 10%)</div>
    </div>
    <div class="card clickable-card" role="button" tabindex="0" onclick="openMetricModal('spy_price')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();openMetricModal('spy_price');}" title="Click to open SPY Price chart dialog">
      <div class="card-title">
        <span>SPY Inception Price</span>
        <span class="card-chart-hint">📈 Chart</span>
      </div>
      <div class="card-value">$<%= sprintf("%.2f", $nav->{spy_price}) %></div>
      <div class="card-sub">Primary S&amp;P 500 Benchmark</div>
    </div>
    <div class="card clickable-card" role="button" tabindex="0" onclick="openMetricModal('alpha')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();openMetricModal('alpha');}" title="Click to open Alpha (vs SPY) chart dialog">
      <div class="card-title">
        <span>Alpha (vs SPY)</span>
        <span class="card-chart-hint">📈 Chart</span>
      </div>
      <div class="card-value <%= $nav->{alpha} >= 0 ? 'positive' : 'negative' %>">
        <%= sprintf("%+.2f", $nav->{alpha} * 100) %>%
      </div>
      <div class="card-sub">Portfolio ROI: <%= sprintf("%.2f", $nav->{portfolio_return} * 100) %>%</div>
    </div>
  </div>

  <!-- Posture & Trigger Architecture -->
  <div class="posture-banner">
    <div class="posture-item">
      <strong>Execution Mode:</strong> Recommendations Only (Review with Financial Advisor Jon; real-world fills logged manually)
    </div>
    <div class="posture-item">
      <strong>Entry Trigger:</strong> Actionable catalysts scoring &ge; 7/10 (AI Silicon, Power Grid, Macro Duration)
    </div>
    <div class="posture-item">
      <strong>Exit Triggers:</strong> Hard Stop-Loss (-10.0%) &bull; Trailing Profit Lock (6.0% trail once &ge; +12.0% gain)
    </div>
    <div class="posture-item">
      <strong>Asset Universe:</strong> Core US Equities, Index/Sector ETFs (<code>QQQ</code>, <code>XLI</code>, <code>SPY</code>, <code>VTI</code>), Energy &amp; Thematic
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
              <td>
                <a href="https://www.marketwatch.com/investing/stock/<%= lc($p->{ticker}) %>" target="_blank" rel="noopener noreferrer" class="catalyst-link" title="Open <%= $p->{ticker} %> on MarketWatch">
                  <strong><%= $p->{ticker} %></strong><span class="external-icon">&#x2197;</span>
                </a>
              </td>
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
                % if ($c->{source_url}) {
                  <div>
                    <a href="<%= $c->{source_url} %>" target="_blank" rel="noopener noreferrer" class="catalyst-link" title="Open source article in new tab">
                      <%= $c->{headline} %><span class="external-icon">&#x2197;</span>
                    </a>
                  </div>
                % } else {
                  <div style="font-weight: 600;"><%= $c->{headline} %></div>
                % }
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

  <!-- Metric History Graph Modal -->
  <div id="metricModal" class="modal-backdrop" onclick="if(event.target === this) closeMetricModal()">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="metricModalTitle">
      <div class="modal-header">
        <div id="metricModalTitle" class="modal-title">📈 Metric Performance Over Time</div>
        <button type="button" class="modal-close" onclick="closeMetricModal()" aria-label="Close">&times;</button>
      </div>
      <div class="modal-body">
        <div class="metric-tabs">
          <button type="button" class="metric-tab" data-metric="total_nav" onclick="switchMetricTab('total_nav')">Total Portfolio NAV</button>
          <button type="button" class="metric-tab" data-metric="cash" onclick="switchMetricTab('cash')">Cash Reserve Floor</button>
          <button type="button" class="metric-tab" data-metric="spy_price" onclick="switchMetricTab('spy_price')">SPY Price</button>
          <button type="button" class="metric-tab" data-metric="alpha" onclick="switchMetricTab('alpha')">Alpha (vs SPY)</button>
        </div>
        <div id="metricStats" class="chart-stats"></div>
        <div class="chart-wrap">
          <div id="chartTooltip" class="chart-tooltip"></div>
          <div id="metricChartContainer"></div>
        </div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-secondary" onclick="closeMetricModal()">Close</button>
      </div>
    </div>
  </div>

  <!-- Evaluate the Market Modal -->
  <div id="evalModal" class="modal-backdrop">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="evalModalTitle">
      <div class="modal-header">
        <div id="evalModalTitle" class="modal-title">⚡ Market Evaluation &amp; Advisor Recommendations</div>
        <button type="button" id="evalCloseX" class="modal-close" onclick="closeEvalModal()" aria-label="Close">&times;</button>
      </div>
      <div class="modal-body">
        <div style="background: var(--card-inner); border: 1px solid var(--border); border-left: 3px solid var(--accent-primary); border-radius: 6px; padding: 10px 14px; margin-bottom: 14px; font-size: 0.82rem; color: var(--text-muted);">
          <strong style="color: var(--text);">Advisor-Only Mode:</strong> Evaluations never execute trades automatically. Review any recommended trades below with <strong style="color: var(--text);">Jon</strong> (your financial advisor). Only record a trade here if it has actually been executed in the real world.
        </div>
        <div class="eval-progress-header">
          <span id="evalStepLabel">Starting market evaluation...</span>
          <span id="evalPercentLabel">0%</span>
        </div>
        <div class="progress-track">
          <div id="evalProgressFill" class="progress-fill"></div>
        </div>

        <button type="button" id="evalLogToggle" class="eval-log-toggle" onclick="toggleEvalLog()">Show execution log ▾</button>
        <pre id="evalLog" class="eval-log"></pre>

        <div id="evalTradesSection" style="display: none;">
          <div class="suggested-trades-header">
            <span>Recommended Trades (For Review with Jon)</span>
            <span id="evalTradesSummary" style="font-size: 0.8rem; font-weight: 500; color: var(--text-muted);"></span>
          </div>
          <div id="evalTradesBody"></div>
        </div>
      </div>
      <div id="evalModalFooter" class="modal-footer">
        <button type="button" id="btnEvalCancel" class="btn btn-secondary" onclick="closeEvalModal()" disabled>Close</button>
        <button type="button" id="btnExecuteTrades" class="btn btn-primary" onclick="executeSelectedTrades()" style="display: none;">Record Selected Real-World Trades</button>
      </div>
    </div>
  </div>

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

    function apiUrl(subpath) {
      const base = window.location.pathname.endsWith('/')
        ? window.location.pathname
        : window.location.pathname + '/';
      return base + subpath.replace(/^\/+/, '');
    }

    function escapeHtml(str) {
      return String(str ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    // Toast Notification
    function showToast(msg) {
      const toast = document.getElementById('toast');
      toast.textContent = msg;
      toast.style.display = 'block';
      setTimeout(() => { toast.style.display = 'none'; }, 4000);
    }

    // =========================================================================
    // Metric History Graph Modal
    // =========================================================================
    const METRIC_META = {
      total_nav: {
        title: 'Total Portfolio NAV Over Time',
        extract: r => Number(r.total_nav || 0),
        format: v => '$' + v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
        baseline: 167876.21,
        baselineLabel: 'Invested Capital ($167,876.21)',
        color: '#388bfd',
      },
      cash: {
        title: 'Cash Reserve Floor Over Time',
        extract: r => Number(r.cash || 0),
        format: v => '$' + v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
        baseline: null,
        color: '#d29922',
      },
      spy_price: {
        title: 'SPY Benchmark Price Over Time',
        extract: r => Number(r.spy_price || 0),
        format: v => '$' + v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
        baseline: null,
        color: '#a371f7',
      },
      alpha: {
        title: 'Alpha (vs SPY) Over Time',
        extract: r => Number(r.alpha || 0) * 100,
        format: v => (v >= 0 ? '+' : '') + v.toFixed(2) + '%',
        baseline: 0,
        baselineLabel: '0.00% Parity',
        color: '#3fb950',
      },
    };

    let cachedHistory = null;
    let activeMetricKey = 'total_nav';

    async function openMetricModal(metricKey) {
      activeMetricKey = metricKey;
      document.getElementById('metricModal').classList.add('active');
      updateMetricTabs();
      document.getElementById('metricChartContainer').innerHTML =
        '<div style="text-align:center; padding:48px; color:var(--text-muted);">Loading historical data...</div>';
      document.getElementById('metricStats').innerHTML = '';

      try {
        const res = await fetch(apiUrl('api/history'));
        const data = await res.json();
        cachedHistory = (data && data.history) ? data.history : [];
        renderMetricChart(cachedHistory, activeMetricKey);
      } catch (err) {
        document.getElementById('metricChartContainer').innerHTML =
          '<div style="text-align:center; padding:48px; color:var(--danger);">Failed to load historical metrics.</div>';
      }
    }

    function switchMetricTab(metricKey) {
      activeMetricKey = metricKey;
      updateMetricTabs();
      if (cachedHistory) {
        renderMetricChart(cachedHistory, activeMetricKey);
      }
    }

    function updateMetricTabs() {
      const meta = METRIC_META[activeMetricKey];
      document.getElementById('metricModalTitle').textContent = '📈 ' + meta.title;
      document.querySelectorAll('.metric-tab').forEach(tab => {
        tab.classList.toggle('active', tab.getAttribute('data-metric') === activeMetricKey);
      });
    }

    function closeMetricModal() {
      document.getElementById('metricModal').classList.remove('active');
      document.getElementById('chartTooltip').style.display = 'none';
    }

    function renderMetricChart(history, metricKey) {
      const meta = METRIC_META[metricKey];
      const container = document.getElementById('metricChartContainer');
      const statsEl = document.getElementById('metricStats');
      const tooltip = document.getElementById('chartTooltip');
      tooltip.style.display = 'none';

      if (!history || history.length === 0) {
        statsEl.innerHTML = '';
        container.innerHTML = '<div style="text-align:center; padding:48px; color:var(--text-muted);">No historical ledger snapshots recorded yet. Run "Evaluate the Market" to record your first snapshot.</div>';
        return;
      }

      const points = history.map(r => ({
        date: r.date,
        value: meta.extract(r),
      }));

      const values = points.map(p => p.value);
      const currentVal = values[values.length - 1];
      const startVal = values[0];
      const minVal = Math.min(...values);
      const maxVal = Math.max(...values);

      statsEl.innerHTML = `
        <div class="chart-stat-box"><div class="chart-stat-label">Latest</div><div class="chart-stat-val">${meta.format(currentVal)}</div></div>
        <div class="chart-stat-box"><div class="chart-stat-label">Inception</div><div class="chart-stat-val">${meta.format(startVal)}</div></div>
        <div class="chart-stat-box"><div class="chart-stat-label">Min</div><div class="chart-stat-val">${meta.format(minVal)}</div></div>
        <div class="chart-stat-box"><div class="chart-stat-label">Max</div><div class="chart-stat-val">${meta.format(maxVal)}</div></div>
        <div class="chart-stat-box"><div class="chart-stat-label">Data Points</div><div class="chart-stat-val">${points.length}</div></div>
      `;

      const width = 740;
      const height = 300;
      const pad = { top: 22, right: 24, bottom: 38, left: 76 };
      const plotW = width - pad.left - pad.right;
      const plotH = height - pad.top - pad.bottom;

      let yMin = minVal;
      let yMax = maxVal;
      if (meta.baseline !== null) {
        yMin = Math.min(yMin, meta.baseline);
        yMax = Math.max(yMax, meta.baseline);
      }
      if (yMin === yMax) {
        const padAmt = Math.abs(yMin) > 0 ? Math.abs(yMin) * 0.05 : 1;
        yMin -= padAmt;
        yMax += padAmt;
      } else {
        const span = yMax - yMin;
        yMin -= span * 0.12;
        yMax += span * 0.12;
      }

      const xFor = i => points.length === 1 ? pad.left + plotW / 2 : pad.left + (i / (points.length - 1)) * plotW;
      const yFor = v => pad.top + ((yMax - v) / (yMax - yMin)) * plotH;

      let gridSvg = '';
      const yTicks = 5;
      for (let i = 0; i <= yTicks; i++) {
        const v = yMin + (i / yTicks) * (yMax - yMin);
        const y = yFor(v);
        gridSvg += `<line x1="${pad.left}" y1="${y}" x2="${width - pad.right}" y2="${y}" stroke="var(--border)" stroke-dasharray="3,3" stroke-width="1"/>`;
        gridSvg += `<text x="${pad.left - 10}" y="${y + 4}" text-anchor="end" fill="var(--text-muted)" font-size="11" font-family="monospace">${escapeHtml(meta.format(v))}</text>`;
      }

      if (meta.baseline !== null && meta.baseline >= yMin && meta.baseline <= yMax) {
        const by = yFor(meta.baseline);
        gridSvg += `<line x1="${pad.left}" y1="${by}" x2="${width - pad.right}" y2="${by}" stroke="var(--text-muted)" stroke-dasharray="6,4" stroke-width="1.2" opacity="0.7"/>`;
        gridSvg += `<text x="${width - pad.right}" y="${by - 5}" text-anchor="end" fill="var(--text-muted)" font-size="10">${escapeHtml(meta.baselineLabel || '')}</text>`;
      }

      const coords = points.map((p, i) => ({ x: xFor(i), y: yFor(p.value), ...p }));
      let pathSvg = '';
      if (coords.length > 1) {
        const lineD = coords.map((c, i) => `${i === 0 ? 'M' : 'L'} ${c.x.toFixed(1)} ${c.y.toFixed(1)}`).join(' ');
        const areaD = `${lineD} L ${coords[coords.length - 1].x.toFixed(1)} ${(pad.top + plotH).toFixed(1)} L ${coords[0].x.toFixed(1)} ${(pad.top + plotH).toFixed(1)} Z`;
        pathSvg += `<path d="${areaD}" fill="${meta.color}" opacity="0.14"/>`;
        pathSvg += `<path d="${lineD}" fill="none" stroke="${meta.color}" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>`;
      }

      let xLabelsSvg = '';
      const maxXLabels = Math.min(points.length, 6);
      const step = points.length <= 1 ? 1 : Math.max(1, Math.floor((points.length - 1) / (maxXLabels - 1)));
      for (let i = 0; i < points.length; i += step) {
        xLabelsSvg += `<text x="${coords[i].x}" y="${height - 10}" text-anchor="middle" fill="var(--text-muted)" font-size="11" font-family="monospace">${escapeHtml(points[i].date)}</text>`;
      }
      if (points.length > 1 && ((points.length - 1) % step !== 0)) {
        const last = coords[coords.length - 1];
        xLabelsSvg += `<text x="${last.x}" y="${height - 10}" text-anchor="middle" fill="var(--text-muted)" font-size="11" font-family="monospace">${escapeHtml(last.date)}</text>`;
      }

      const dotsSvg = coords.map((c, idx) => `
        <circle cx="${c.x.toFixed(1)}" cy="${c.y.toFixed(1)}" r="${coords.length === 1 ? 6 : 4}" fill="${meta.color}" stroke="var(--card-bg)" stroke-width="2" class="chart-dot" data-idx="${idx}" style="cursor:pointer;"/>
      `).join('');

      const noteHtml = points.length === 1
        ? `<div style="text-align:center; font-size:0.78rem; color:var(--text-muted); margin-top:6px;">Showing 1 day of data (${escapeHtml(points[0].date)}). Additional daily evaluations will plot the trend over time.</div>`
        : '';

      container.innerHTML = `
        <svg viewBox="0 0 ${width} ${height}" style="width:100%; height:auto; display:block;" id="metricChartSvg">
          ${gridSvg}
          ${xLabelsSvg}
          ${pathSvg}
          ${dotsSvg}
        </svg>
        ${noteHtml}
      `;

      const svg = document.getElementById('metricChartSvg');
      svg.querySelectorAll('.chart-dot').forEach(dot => {
        dot.addEventListener('mouseenter', (e) => {
          const idx = Number(dot.getAttribute('data-idx'));
          const pt = coords[idx];
          tooltip.innerHTML = `<strong>${escapeHtml(pt.date)}</strong><br>${escapeHtml(meta.format(pt.value))}`;
          tooltip.style.display = 'block';
          const wrapRect = container.parentElement.getBoundingClientRect();
          const dotRect = dot.getBoundingClientRect();
          tooltip.style.left = Math.min(wrapRect.width - 130, Math.max(8, dotRect.left - wrapRect.left - 35)) + 'px';
          tooltip.style.top = Math.max(8, dotRect.top - wrapRect.top - 52) + 'px';
        });
        dot.addEventListener('mouseleave', () => {
          tooltip.style.display = 'none';
        });
      });
    }

    // =========================================================================
    // Evaluate the Market Modal & Proposed Trade Execution
    // =========================================================================
    let evalRunning = false;
    let evalPollTimer = null;
    let currentProposedTrades = [];
    let evalShouldReloadOnClose = false;

    function toggleEvalLog() {
      const logEl = document.getElementById('evalLog');
      const btn = document.getElementById('evalLogToggle');
      const isOpen = logEl.classList.toggle('open');
      btn.textContent = isOpen ? 'Hide execution log ▴' : 'Show execution log ▾';
    }

    function closeEvalModal() {
      if (evalRunning) return;
      if (evalPollTimer) {
        clearInterval(evalPollTimer);
        evalPollTimer = null;
      }
      document.getElementById('evalModal').classList.remove('active');
      if (evalShouldReloadOnClose) {
        window.location.reload();
      }
    }

    async function evaluateMarket() {
      if (evalRunning) return;
      evalRunning = true;
      evalShouldReloadOnClose = false;
      currentProposedTrades = [];

      const btn = document.getElementById('btnEvaluate');
      const origText = btn.innerHTML;
      btn.disabled = true;
      btn.innerHTML = '<span>⏳ Evaluating Market...</span>';

      // Reset & open modal
      document.getElementById('evalStepLabel').textContent = 'Starting market evaluation...';
      document.getElementById('evalPercentLabel').textContent = '5%';
      document.getElementById('evalProgressFill').style.width = '5%';
      document.getElementById('evalLog').textContent = '';
      document.getElementById('evalLog').classList.remove('open');
      document.getElementById('evalLogToggle').textContent = 'Show execution log ▾';
      document.getElementById('evalTradesSection').style.display = 'none';
      document.getElementById('evalTradesBody').innerHTML = '';
      document.getElementById('btnExecuteTrades').style.display = 'none';
      document.getElementById('btnEvalCancel').disabled = true;
      document.getElementById('btnEvalCancel').textContent = 'Close';
      document.getElementById('evalCloseX').disabled = true;
      document.getElementById('evalModal').classList.add('active');

      try {
        const res = await fetch(apiUrl('api/evaluate/start'), { method: 'POST' });
        const startData = await res.json();
        if (!startData.success || !startData.job_id) {
          throw new Error(startData.message || 'Failed to start evaluation job.');
        }
        pollEvaluationStatus(startData.job_id, btn, origText);
      } catch (err) {
        evalRunning = false;
        btn.disabled = false;
        btn.innerHTML = origText;
        document.getElementById('evalStepLabel').textContent = 'Error starting evaluation: ' + err.message;
        document.getElementById('evalPercentLabel').textContent = '100%';
        document.getElementById('evalProgressFill').style.width = '100%';
        document.getElementById('btnEvalCancel').disabled = false;
        document.getElementById('evalCloseX').disabled = false;
      }
    }

    function pollEvaluationStatus(jobId, btn, origText) {
      evalPollTimer = setInterval(async () => {
        try {
          const res = await fetch(apiUrl('api/evaluate/status/' + encodeURIComponent(jobId)));
          const st = await res.json();

          document.getElementById('evalStepLabel').textContent = st.label || 'Evaluating...';
          const pct = Math.min(100, Math.max(0, Number(st.percent || 0)));
          document.getElementById('evalPercentLabel').textContent = pct + '%';
          document.getElementById('evalProgressFill').style.width = pct + '%';

          if (st.log) {
            const logEl = document.getElementById('evalLog');
            logEl.textContent = st.log;
            logEl.scrollTop = logEl.scrollHeight;
          }

          if (st.done) {
            clearInterval(evalPollTimer);
            evalPollTimer = null;
            evalRunning = false;
            btn.disabled = false;
            btn.innerHTML = origText;
            document.getElementById('btnEvalCancel').disabled = false;
            document.getElementById('evalCloseX').disabled = false;

            if (st.success) {
              evalShouldReloadOnClose = true;
              currentProposedTrades = Array.isArray(st.proposed_trades) ? st.proposed_trades : [];
              renderProposedTrades(currentProposedTrades);
            } else {
              document.getElementById('evalLog').classList.add('open');
              document.getElementById('evalLogToggle').textContent = 'Hide execution log ▴';
              document.getElementById('evalTradesSection').style.display = 'block';
              document.getElementById('evalTradesBody').innerHTML =
                `<div class="eval-empty-box" style="color:var(--danger); border-color:var(--danger);">Market evaluation failed. Review the execution log above for details.</div>`;
            }
          }
        } catch (err) {
          // Transient polling error; keep trying until done or user reloads
        }
      }, 450);
    }

    function renderProposedTrades(trades) {
      const section = document.getElementById('evalTradesSection');
      const body = document.getElementById('evalTradesBody');
      const execBtn = document.getElementById('btnExecuteTrades');
      const cancelBtn = document.getElementById('btnEvalCancel');
      section.style.display = 'block';

      if (!trades || trades.length === 0) {
        document.getElementById('evalTradesSummary').textContent = '0 trades suggested';
        body.innerHTML = `
          <div class="eval-empty-box">
            No new trades suggested right now. All actionable catalysts (&ge; 7/10) are either already held, constrained by cash/sector limits, or no new catalysts met the threshold.
          </div>
        `;
        execBtn.style.display = 'none';
        cancelBtn.textContent = 'Done & Refresh';
        return;
      }

      const rowsHtml = trades.map((t, idx) => {
        const isBuy = (t.action || '').toUpperCase() === 'BUY';
        const scoreBadge = t.catalyst_score ? `<span class="score-badge score-high">${t.catalyst_score}/10</span>` : '-';
        return `
          <tr>
            <td style="text-align:center;">
              <label class="toggle-switch" title="Toggle only if you executed this trade in the real world with Jon">
                <input type="checkbox" class="trade-toggle" data-idx="${idx}" onchange="updateSelectedSummary()">
                <span class="toggle-slider"></span>
              </label>
            </td>
            <td><span class="${isBuy ? 'action-buy' : 'action-sell'}">${escapeHtml(t.action)}</span></td>
            <td><strong>${escapeHtml(t.ticker)}</strong><div style="font-size:0.72rem; color:var(--text-muted);">${escapeHtml(t.sector || '')}</div></td>
            <td>${Number(t.shares)}</td>
            <td>$${Number(t.price).toFixed(2)}</td>
            <td><strong>$${Number(t.total_amount).toFixed(2)}</strong></td>
            <td>${scoreBadge}</td>
            <td style="font-size:0.78rem; color:var(--text-muted); max-width:240px;">${escapeHtml(t.rationale || '')}</td>
          </tr>
        `;
      }).join('');

      body.innerHTML = `
        <div class="table-container" style="margin-bottom:0;">
          <table>
            <thead>
              <tr>
                <th style="text-align:center;">Traded?</th>
                <th>Recommendation</th>
                <th>Ticker</th>
                <th>Shares</th>
                <th>Est. Price</th>
                <th>Est. Total</th>
                <th>Score</th>
                <th>Rationale for Jon</th>
              </tr>
            </thead>
            <tbody>${rowsHtml}</tbody>
          </table>
        </div>
      `;

      cancelBtn.textContent = 'Close (Keep Recommendations Only)';
      execBtn.style.display = 'inline-flex';
      updateSelectedSummary();
    }

    function updateSelectedSummary() {
      const toggles = Array.from(document.querySelectorAll('.trade-toggle'));
      let count = 0;
      let totalAmt = 0;
      toggles.forEach(cb => {
        if (cb.checked) {
          count++;
          const t = currentProposedTrades[Number(cb.getAttribute('data-idx'))];
          if (t) totalAmt += Number(t.total_amount || 0);
        }
      });
      document.getElementById('evalTradesSummary').textContent =
        `${currentProposedTrades.length} recommended (${count} marked as executed: $${totalAmt.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })})`;
      const execBtn = document.getElementById('btnExecuteTrades');
      execBtn.disabled = count === 0;
      execBtn.textContent = `Record Executed Trades (${count})`;
    }

    async function executeSelectedTrades() {
      const selected = [];
      document.querySelectorAll('.trade-toggle').forEach(cb => {
        if (cb.checked) {
          const t = currentProposedTrades[Number(cb.getAttribute('data-idx'))];
          if (t) selected.push(t);
        }
      });
      if (selected.length === 0) return;

      const execBtn = document.getElementById('btnExecuteTrades');
      execBtn.disabled = true;
      execBtn.textContent = 'Executing...';

      try {
        const res = await fetch(apiUrl('api/trades/execute'), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ trades: selected }),
        });
        const data = await res.json();
        if (data.success) {
          showToast(data.message || 'Trades executed successfully!');
          evalShouldReloadOnClose = false;
          document.getElementById('evalModal').classList.remove('active');
          setTimeout(() => { window.location.reload(); }, 900);
        } else {
          showToast('Trade execution failed: ' + (data.message || 'Unknown error'));
          execBtn.disabled = false;
          updateSelectedSummary();
        }
      } catch (err) {
        showToast('Error communicating with AI Trader backend.');
        execBtn.disabled = false;
        updateSelectedSummary();
      }
    }

    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        if (document.getElementById('metricModal').classList.contains('active')) {
          closeMetricModal();
        } else if (document.getElementById('evalModal').classList.contains('active') && !evalRunning) {
          closeEvalModal();
        }
      }
    });

    // Initial theme load
    const savedTheme = localStorage.getItem('ai_trader_theme') || 'system';
    setThemeMode(savedTheme, false);
  </script>

</body>
</html>
