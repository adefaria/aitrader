package Trader::DB;

use strict;
use warnings;
use DBI;
use POSIX qw(strftime);
use Mojo::UserAgent;

use Exporter 'import';
our @EXPORT_OK = qw(
    get_dbh
    init_schema
    seed_initial_state
    fetch_market_price
    fetch_market_indices
    get_latest_nav
    get_positions
    record_trade
    record_nav
    record_catalyst
    get_unscored_catalysts
    update_catalyst_score
    get_actionable_catalysts
    upsert_position
    close_position
    get_git_commit
);

sub get_dbh {
    my ($db_path) = @_;
    $db_path //= $ENV{DB_PATH} // 'data/paper_ledger.db';

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_path",
        "", "",
        {
            RaiseError     => 1,
            PrintError     => 0,
            sqlite_unicode => 1,
            AutoCommit     => 1,
        }
    ) or die "Failed to connect to SQLite database at $db_path: $DBI::errstr\n";

    $dbh->do("PRAGMA journal_mode = WAL");
    $dbh->do("PRAGMA foreign_keys = ON");
    return $dbh;
}

sub init_schema {
    my ($dbh) = @_;

    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS positions (
            ticker TEXT PRIMARY KEY,
            shares REAL NOT NULL,
            cost_basis REAL NOT NULL,
            high_water_mark REAL NOT NULL,
            sector TEXT,
            entry_date TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    });

    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS trades (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            ticker TEXT NOT NULL,
            action TEXT NOT NULL,
            shares REAL NOT NULL,
            fill_price REAL NOT NULL,
            total_amount REAL NOT NULL,
            catalyst_score INTEGER,
            spec_version TEXT NOT NULL,
            rationale TEXT
        )
    });

    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS daily_nav (
            date TEXT PRIMARY KEY,
            cash REAL NOT NULL,
            positions_value REAL NOT NULL,
            total_nav REAL NOT NULL,
            spy_price REAL NOT NULL,
            portfolio_return REAL DEFAULT 0.0,
            spy_return REAL DEFAULT 0.0,
            alpha REAL DEFAULT 0.0,
            high_water_mark REAL NOT NULL,
            drawdown REAL DEFAULT 0.0
        )
    });

    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS catalyst_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            ticker TEXT,
            headline TEXT NOT NULL,
            summary TEXT,
            source_url TEXT,
            theme TEXT,
            score INTEGER,
            rationale TEXT,
            status TEXT DEFAULT 'NEW'
        )
    });

    return 1;
}

sub fetch_market_price {
    my ($ticker) = @_;
    $ticker //= 'SPY';

    my $ua = Mojo::UserAgent->new;
    $ua->transactor->name('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    $ua->inactivity_timeout(3);
    $ua->connect_timeout(2);

    my $price;
    for my $host ('query1.finance.yahoo.com', 'query2.finance.yahoo.com') {
        my $url = "https://$host/v8/finance/chart/$ticker?interval=1d&range=5d";
        eval {
            my $tx = $ua->get($url);
            if ($tx->result->is_success) {
                my $json = $tx->result->json;
                my $meta = $json->{chart}{result}[0]{meta};
                $price = $meta->{regularMarketPrice} // $meta->{chartPreviousClose};
            }
        };
        last if defined $price && $price > 0;
    }

    return $price;
}

sub fetch_market_indices {
    my $ua = Mojo::UserAgent->new;
    $ua->transactor->name('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    $ua->inactivity_timeout(4);
    $ua->connect_timeout(2);

    my @indices = (
        { name => 'DOW',    symbol => '^DJI' },
        { name => 'S&P 500',symbol => '^GSPC' },
        { name => 'NASDAQ', symbol => '^IXIC' },
    );

    my @results;
    for my $item (@indices) {
        my $sym = $item->{symbol};
        my $price = 0.0;
        my $change = 0.0;
        my $pct = 0.0;
        eval {
            my $tx = $ua->get("https://query1.finance.yahoo.com/v8/finance/chart/$sym?interval=1d&range=2d");
            if ($tx->result->is_success) {
                my $meta = $tx->result->json->{chart}{result}[0]{meta};
                $price = $meta->{regularMarketPrice} // 0.0;
                my $prev = $meta->{chartPreviousClose} // $price;
                $change = $price - $prev;
                $pct = ($prev && $prev > 0) ? (($change / $prev) * 100) : 0.0;
            }
        };
        push @results, {
            name   => $item->{name},
            symbol => $item->{symbol},
            price  => $price,
            change => $change,
            pct    => $pct,
        };
    }
    return \@results;
}

sub seed_initial_state {
    my ($dbh, $spy_price, $starting_capital) = @_;
    $starting_capital //= 10000.00;
    my $today = strftime("%Y-%m-%d", localtime);

    my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM daily_nav");
    if (!$count) {
        my $sth = $dbh->prepare(qq{
            INSERT INTO daily_nav (
                date, cash, positions_value, total_nav,
                spy_price, portfolio_return, spy_return,
                alpha, high_water_mark, drawdown
            ) VALUES (?, ?, ?, ?, ?, 0.0, 0.0, 0.0, ?, 0.0)
        });
        $sth->execute($today, $starting_capital, 0.0, $starting_capital, $spy_price, $starting_capital);
        return 1;
    }
    return 0;
}

sub get_latest_nav {
    my ($dbh) = @_;
    my $sth = $dbh->prepare(qq{
        SELECT * FROM daily_nav ORDER BY date DESC LIMIT 1
    });
    $sth->execute();
    return $sth->fetchrow_hashref();
}

sub get_positions {
    my ($dbh) = @_;
    my $sth = $dbh->prepare(qq{
        SELECT * FROM positions WHERE shares > 0 ORDER BY ticker ASC
    });
    $sth->execute();
    return $sth->fetchall_arrayref({});
}

sub upsert_position {
    my ($dbh, $ticker, $shares, $cost_basis, $high_water_mark, $sector) = @_;
    my $now = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $today = strftime("%Y-%m-%d", localtime);

    my $sth = $dbh->prepare(qq{
        INSERT INTO positions (ticker, shares, cost_basis, high_water_mark, sector, entry_date, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(ticker) DO UPDATE SET
            shares = excluded.shares,
            cost_basis = excluded.cost_basis,
            high_water_mark = excluded.high_water_mark,
            sector = COALESCE(excluded.sector, positions.sector),
            updated_at = excluded.updated_at
    });
    $sth->execute($ticker, $shares, $cost_basis, $high_water_mark, $sector, $today, $now);
    return 1;
}

sub close_position {
    my ($dbh, $ticker) = @_;
    my $sth = $dbh->prepare("DELETE FROM positions WHERE ticker = ?");
    $sth->execute($ticker);
    return 1;
}

sub record_trade {
    my ($dbh, %args) = @_;
    my $timestamp = $args{timestamp} // strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $spec_version = $args{spec_version} // get_git_commit();
    my $total_amount = $args{total_amount} // ($args{shares} * $args{fill_price});

    my $sth = $dbh->prepare(qq{
        INSERT INTO trades (timestamp, ticker, action, shares, fill_price, total_amount, catalyst_score, spec_version, rationale)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute(
        $timestamp,
        $args{ticker},
        $args{action},
        $args{shares},
        $args{fill_price},
        $total_amount,
        $args{catalyst_score},
        $spec_version,
        $args{rationale}
    );
    return $dbh->sqlite_last_insert_rowid();
}

sub record_nav {
    my ($dbh, %args) = @_;
    my $sth = $dbh->prepare(qq{
        INSERT OR REPLACE INTO daily_nav (
            date, cash, positions_value, total_nav, spy_price,
            portfolio_return, spy_return, alpha, high_water_mark, drawdown
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute(
        $args{date},
        $args{cash},
        $args{positions_value},
        $args{total_nav},
        $args{spy_price},
        $args{portfolio_return} // 0.0,
        $args{spy_return} // 0.0,
        $args{alpha} // 0.0,
        $args{high_water_mark},
        $args{drawdown} // 0.0
    );
    return 1;
}

sub record_catalyst {
    my ($dbh, %args) = @_;
    my $timestamp = $args{timestamp} // strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $sth = $dbh->prepare(qq{
        INSERT INTO catalyst_events (timestamp, ticker, headline, summary, source_url, theme, score, rationale, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute(
        $timestamp,
        $args{ticker},
        $args{headline},
        $args{summary},
        $args{source_url},
        $args{theme},
        $args{score},
        $args{rationale},
        $args{status} // 'NEW'
    );
    return $dbh->sqlite_last_insert_rowid();
}

sub get_unscored_catalysts {
    my ($dbh) = @_;
    my $sth = $dbh->prepare("SELECT * FROM catalyst_events WHERE status IN ('NEW', 'INGESTED') ORDER BY id ASC");
    $sth->execute();
    return $sth->fetchall_arrayref({});
}

sub update_catalyst_score {
    my ($dbh, $id, $score, $theme, $rationale) = @_;
    my $sth = $dbh->prepare(qq{
        UPDATE catalyst_events
        SET score = ?, theme = COALESCE(?, theme), rationale = ?, status = 'SCORED'
        WHERE id = ?
    });
    $sth->execute($score, $theme, $rationale, $id);
    return 1;
}

sub get_actionable_catalysts {
    my ($dbh, $min_score) = @_;
    $min_score //= 7;
    my $sth = $dbh->prepare("SELECT * FROM catalyst_events WHERE score >= ? AND status = 'SCORED' ORDER BY score DESC, id DESC");
    $sth->execute($min_score);
    return $sth->fetchall_arrayref({});
}

sub get_git_commit {
    my $commit = `git rev-parse HEAD 2>/dev/null`;
    chomp($commit) if defined $commit;
    return $commit || 'git-unknown';
}

1;
