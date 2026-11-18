#!/usr/bin/env perl
use strict;
use warnings;
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Getopt::Long qw(:config no_ignore_case);
use Pod::Usage;
use POSIX qw(strftime);
use Sys::Hostname qw(hostname);
use Mojo::UserAgent;
use Trader::DB qw(get_dbh init_schema seed_initial_state fetch_market_price get_latest_nav get_positions get_git_commit record_run_log);

eval {
    require Dotenv;
    Dotenv->load if -f '.env';
};

$| = 1;

my $dry_run = 0;
my $propose = 0;
my $help    = 0;
my $trigger = (-t STDIN) ? 'cli' : 'cron';
my $db_path = $ENV{DB_PATH} // "$RealBin/../data/paper_ledger.db";
my $capital = $ENV{STARTING_CAPITAL} // 167876.21;
my $benchmark = $ENV{BENCHMARK_TICKER} // 'SPY';
my $exec_mode = $ENV{EXECUTION_MODE} // 'ADVISOR_BRIEF';

GetOptions(
    'dry-run'   => \$dry_run,
    'propose'   => \$propose,
    'trigger=s' => \$trigger,
    'db=s'      => \$db_path,
    'help|h'    => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

my $current_host = lc(hostname() // '');
if ($trigger eq 'cron' && $current_host =~ /earth/) {
    print "[run_daily] Staging server ($current_host) detected; skipping automated cron/timer execution.\n";
    exit 0;
}

# Enforce advisor-only recommendations mode unless explicitly overridden
$propose = 1 if uc($exec_mode) eq 'ADVISOR_BRIEF';

print "========================================================\n";
print " AI TRADER — Daily Pipeline Orchestrator (Perl Layer 3) \n";
print " Mode: " . ($dry_run ? "DRY-RUN VERIFICATION" : ($propose ? "ADVISOR RECOMMENDATIONS ONLY" : "PRODUCTION SIMULATION")) . "\n";
print " Git Commit: " . get_git_commit() . "\n";
print " Timestamp:  " . strftime("%Y-%m-%d %H:%M:%S", localtime) . "\n";
print "========================================================\n\n";

# STEP 1: Ledger & Database Verification
print "--- [Step 1/5] Ledger Initialization & Benchmark Check ---\n";
my $dbh = get_dbh($db_path);
init_schema($dbh);

my $spy_price = fetch_market_price($benchmark);
if (defined $spy_price) {
    printf "[Step 1] Real-time market data verified: %s closing/market price = \$%.2f\n", $benchmark, $spy_price;
} else {
    warn "[Step 1] WARNING: Live market data unreachable. Using fallback benchmark price (500.00).\n";
    $spy_price = 500.00;
}

my $seeded = seed_initial_state($dbh, $spy_price, $capital);
if ($seeded) {
    printf "[Step 1] Initialized new ledger seeded with \$%.2f cash (Day 0)\n", $capital;
} else {
    my $nav = get_latest_nav($dbh);
    printf "[Step 1] Existing ledger verified. Total NAV: \$%.2f | Cash: \$%.2f | SPY: \$%.2f\n",
        $nav->{total_nav}, $nav->{cash}, $nav->{spy_price};
}
$dbh->disconnect;

# STEP 2: Gemini REST API Connectivity Check
print "\n--- [Step 2/5] Gemini REST API Connectivity Check ---\n";
my $api_key = $ENV{GEMINI_API_KEY};
if (!$api_key) {
    die "[Step 2] FATAL: GEMINI_API_KEY is not defined in environment or .env!\n";
}

if ($dry_run) {
    my $ua = Mojo::UserAgent->new;
    $ua->inactivity_timeout(15);
    $ua->connect_timeout(10);
    my $model = $ENV{GEMINI_MODEL} // 'gemini-2.5-flash';
    my $endpoint = "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$api_key";

    my $gemini_tx = $ua->post($endpoint => json => {
        contents => [
            { parts => [ { text => 'Antigravity Layer 2 connection test: reply with status ok.' } ] }
        ]
    });

    if ($gemini_tx->result->is_success) {
        my $reply = $gemini_tx->result->json->{candidates}[0]{content}{parts}[0]{text} // '';
        $reply =~ s/^\s+|\s+$//g;
        printf "[Step 2] Gemini REST API connectivity verified (%s): %s\n", $model, $reply;
    } elsif ($gemini_tx->result->code == 429) {
        warn "[Step 2] WARNING: Gemini API daily quota exceeded (429). Continuing with cached/scored catalysts.\n";
    } else {
        die sprintf("[Step 2] FATAL: Gemini API request failed: %s\n", $gemini_tx->result->body);
    }
} else {
    print "[Step 2] GEMINI_API_KEY configured (skipping redundant ping to preserve API quota).\n";
}

# STEP 3: News Ingestion Stage
print "\n--- [Step 3/5] News & Catalyst Ingestion ---\n";
my $ingest_cmd = "perl -Ilocal/lib/perl5 -I$RealBin/lib $RealBin/ingest_news.pl" . ($dry_run ? " --dry-run" : "");
system($ingest_cmd) == 0 or die "[Step 3] News ingestion failed with code $?\n";

# STEP 4: Catalyst Evaluation Stage
print "\n--- [Step 4/5] Catalyst Scoring via Gemini API ---\n";
my $eval_cmd = "perl -Ilocal/lib/perl5 -I$RealBin/lib $RealBin/evaluate_catalysts.pl" . ($dry_run ? " --dry-run" : "");
system($eval_cmd) == 0 or die "[Step 4] Catalyst evaluation failed with code $?\n";

# STEP 5: Risk Engine & Daily Reporting
print "\n--- [Step 5/5] Risk Checks & Daily Reporting ---\n";
my $engine_cmd = "perl -Ilocal/lib/perl5 -I$RealBin/lib $RealBin/portfolio_engine.pl"
    . ($dry_run ? " --dry-run" : "")
    . ($propose ? " --propose" : "");
system($engine_cmd) == 0 or die "[Step 5] Portfolio engine failed with code $?\n";

my $report_cmd = "perl -Ilocal/lib/perl5 -I$RealBin/lib $RealBin/generate_report.pl" . ($dry_run ? " --dry-run" : "");
system($report_cmd) == 0 or die "[Step 5] Report generation failed with code $?\n";

if (!$dry_run) {
    my $end_dbh = get_dbh($db_path);
    my $end_nav = get_latest_nav($end_dbh);
    my $end_pos = get_positions($end_dbh);
    my ($scored_today) = $end_dbh->selectrow_array(
        "SELECT COUNT(*) FROM catalyst_events WHERE status = 'SCORED' AND timestamp >= date('now', 'localtime')"
    );
    record_run_log(
        $end_dbh,
        run_type         => 'market_eval',
        trigger_source   => $trigger,
        summary          => sprintf("Full 5-stage market evaluation complete (%d catalysts scored, %d open holdings)", $scored_today // 0, scalar(@$end_pos)),
        holdings_checked => scalar(@$end_pos),
        catalysts_scored => $scored_today // 0,
        total_nav        => $end_nav ? $end_nav->{total_nav} : undef,
    );
    $end_dbh->disconnect;
}

print "\n========================================================\n";
print " End-to-end daily pipeline verification SUCCESSFUL!     \n";
print "========================================================\n";

__END__

=head1 NAME

run_daily.pl - Daily end-to-end orchestrator for the AI trading architecture

=head1 SYNOPSIS

run_daily.pl [options]

 Options:
   --dry-run       Perform dry-run verification of market data, Gemini API, risk, and ledger
   --db=PATH       Path to SQLite database (default: data/paper_ledger.db)
   --help, -h      Show this help message

=cut
