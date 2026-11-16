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
my $capital   = $ENV{STARTING_CAPITAL} // 10000.00;
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
}

print "[init_db] Initializing SQLite ledger at: $db_path\n";
my $dbh = get_dbh($db_path);
init_schema($dbh);

print "[init_db] Fetching current $benchmark benchmark price via Mojo::UserAgent...\n";
my $spy_price = fetch_market_price($benchmark);
if (!defined $spy_price) {
    warn "[init_db] WARNING: Could not fetch real-time $benchmark price. Using fallback baseline (500.00).\n";
    $spy_price = 500.00;
} else {
    printf "[init_db] Real-time %s benchmark price fetched: \$%.2f\n", $benchmark, $spy_price;
}

my $seeded = seed_initial_state($dbh, $spy_price, $capital);
if ($seeded) {
    printf "[init_db] Database successfully initialized and seeded with \$%.2f cash and %s=\$%.2f\n",
        $capital, $benchmark, $spy_price;
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
