#!/usr/bin/env perl
use strict;
use warnings;
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Getopt::Long qw(:config no_ignore_case);
use Pod::Usage;
use Trader::DB qw(get_dbh init_schema seed_initial_state fetch_market_price get_latest_nav);

# Load .env if available
eval {
    require Dotenv;
    Dotenv->load if -f '.env';
};

my $db_path   = $ENV{DB_PATH} // "$RealBin/../data/paper_ledger.db";
my $capital   = $ENV{STARTING_CAPITAL} // 167876.21;
my $benchmark = $ENV{BENCHMARK_TICKER} // 'SPY';
my $force     = 0;
my $help      = 0;

GetOptions(
    'db=s'      => \$db_path,
    'capital=f' => \$capital,
    'force'     => \$force,
    'help|h'    => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

# Ensure parent directory exists
my ($dir) = $db_path =~ m{^(.*)/[^/]+$};
if ($dir && !-d $dir) {
    mkdir $dir or die "Could not create directory $dir: $!\n";
}

if ($force && -f $db_path) {
    unlink $db_path or warn "Could not remove existing database $db_path: $!\n";
    unlink "$db_path-wal" if -f "$db_path-wal";
    unlink "$db_path-shm" if -f "$db_path-shm";
}

print "[init_db] Initializing SQLite ledger at: $db_path\n";
my $dbh = get_dbh($db_path);
init_schema($dbh);

my ($pos_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM positions");
if (!$pos_count) {
    print "[init_db] Seeding Andrew DeFaria's Raymond James portfolio holdings...\n";
    my $cash = 8743.57; # Raymond James Bank Deposit Program

    my @holdings = (
        {
            ticker     => 'DIS',
            name       => 'DISNEY WALT COMPANY',
            shares     => 30.0,
            cost_basis => 102.00,
            price      => 116.755,
            total_cost => 3060.00,
            sector     => 'Communication Services & Media',
            term       => 'Long',
        },
        {
            ticker     => 'HD',
            name       => 'HOME DEPOT INCORPORATED',
            shares     => 10.0,
            cost_basis => 285.75,
            price      => 338.76,
            total_cost => 2857.50,
            sector     => 'Consumer Cyclical & Retail',
            term       => 'Long',
        },
        {
            ticker     => 'QQQ',
            name       => 'INVESCO QQQ TRUST',
            shares     => 72.0,
            cost_basis => 555.935,
            price      => 654.469,
            total_cost => 40027.32,
            sector     => 'Large-Cap Tech Index Funds',
            term       => 'Mixed',
        },
        {
            ticker     => 'MSFT',
            name       => 'MICROSOFT CORPORATION',
            shares     => 36.0,
            cost_basis => 195.1394,
            price      => 505.768,
            total_cost => 7025.02,
            sector     => 'Enterprise Software & AI Cloud',
            term       => 'Long',
        },
        {
            ticker     => 'NVDA',
            name       => 'NVIDIA CORPORATION',
            shares     => 432.0,
            cost_basis => 39.2537,
            price      => 153.975,
            total_cost => 16957.58,
            sector     => 'Semiconductors & Compute',
            term       => 'Mixed',
        },
        {
            ticker     => 'SBUX',
            name       => 'STARBUCKS CORPORATION',
            shares     => 43.0,
            cost_basis => 69.6133,
            price      => 107.52,
            total_cost => 2993.37,
            sector     => 'Consumer Cyclical & Retail',
            term       => 'Long',
        },
        {
            ticker     => 'XLI',
            name       => 'STATE STREET INDUSTRIAL SELECT SECTOR SPDR ETF',
            shares     => 459.0,
            cost_basis => 102.6271,
            price      => 164.48,
            total_cost => 47105.84,
            sector     => 'Industrial Sector ETF',
            term       => 'Long',
        },
        {
            ticker     => 'SPY',
            name       => 'STATE STREET SPDR S&P 500 ETF TRUST',
            shares     => 19.0,
            cost_basis => 765.7258,
            price      => 730.851,
            total_cost => 14548.79,
            sector     => 'Broad Market Index Funds',
            term       => 'Short',
        },
        {
            ticker     => 'UNH',
            name       => 'UNITEDHEALTH GROUP INCORPORATED',
            shares     => 25.0,
            cost_basis => 242.61,
            price      => 388.05,
            total_cost => 6065.25,
            sector     => 'Healthcare & Managed Care',
            term       => 'Long',
        },
        {
            ticker     => 'VTI',
            name       => 'VANGUARD MORNINGSTAR TOTAL STOCK MARKET ETF',
            shares     => 30.0,
            cost_basis => 324.9467,
            price      => 359.63,
            total_cost => 9748.40,
            sector     => 'Broad Market Index Funds',
            term       => 'Long',
        },
    );

    my $positions_val = 0.0;
    for my $h (@holdings) {
        my $cur_price = fetch_market_price($h->{ticker}) // $h->{price};
        my $hwm = ($cur_price > $h->{cost_basis}) ? $cur_price : $h->{cost_basis};
        $hwm = $h->{price} if $h->{price} > $hwm;

        Trader::DB::upsert_position(
            $dbh,
            $h->{ticker},
            $h->{shares},
            $h->{cost_basis},
            $hwm,
            $h->{sector}
        );

        Trader::DB::record_trade(
            $dbh,
            ticker         => $h->{ticker},
            action         => 'BUY',
            shares         => $h->{shares},
            fill_price     => $h->{cost_basis},
            total_amount   => $h->{total_cost},
            catalyst_score => undef,
            rationale      => sprintf("Initial Raymond James portfolio position (%s: %s term, Invested: \$%.2f)", $h->{name}, $h->{term}, $h->{total_cost}),
        );

        $positions_val += $h->{shares} * $cur_price;
    }

    my $spy_price = fetch_market_price($benchmark) // 730.85;
    my $total_nav = $cash + $positions_val;
    my $portfolio_ret = ($total_nav - $capital) / $capital;
    my $today = POSIX::strftime("%Y-%m-%d", localtime);

    Trader::DB::record_nav(
        $dbh,
        date             => $today,
        cash             => $cash,
        positions_value  => $positions_val,
        total_nav        => $total_nav,
        spy_price        => $spy_price,
        portfolio_return => $portfolio_ret,
        spy_return       => 0.0,
        alpha            => $portfolio_ret,
        high_water_mark  => $total_nav,
        drawdown         => 0.0,
    );

    printf "[init_db] Seeded %d actual positions + \$%.2f cash. Total NAV: \$%.2f (Invested Capital: \$%.2f, Gain: %+.2f%%)\n",
        scalar(@holdings), $cash, $total_nav, $capital, $portfolio_ret * 100;
} else {
    my $nav = get_latest_nav($dbh);
    printf "[init_db] Database already contains records. Latest NAV: \$%.2f (Cash: \$%.2f, SPY: \$%.2f)\n",
        $nav->{total_nav}, $nav->{cash}, $nav->{spy_price};
}

$dbh->disconnect;

__END__

=head1 NAME

init_db.pl - Initialize SQLite database for paper trading ledger

=head1 SYNOPSIS

init_db.pl [options]

 Options:
   --db=PATH       Path to SQLite database (default: data/paper_ledger.db)
   --capital=NUM   Initial starting capital (default: 10000.00)
   --force         Overwrite existing database
   --help, -h      Show this help message

=cut
