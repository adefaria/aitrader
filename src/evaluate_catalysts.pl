#!/usr/bin/env perl
use strict;
use warnings;
use local::lib 'local';
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Getopt::Long qw(:config no_ignore_case);
use Pod::Usage;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use Trader::DB qw(get_dbh get_unscored_catalysts update_catalyst_score);

eval {
    require Dotenv;
    Dotenv->load if -f '.env';
};

my $dry_run = 0;
my $help    = 0;
my $model   = $ENV{GEMINI_MODEL} // 'gemini-2.5-flash';

GetOptions(
    'dry-run' => \$dry_run,
    'model=s' => \$model,
    'help|h'  => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

my $api_key = $ENV{GEMINI_API_KEY};
die "[evaluate_catalysts] ERROR: GEMINI_API_KEY environment variable is not set.\n" unless $api_key;

my $dbh = get_dbh();
my $unscored = get_unscored_catalysts($dbh);

if ($dry_run) {
    print "[evaluate_catalysts] Testing Gemini REST API connectivity ($model via Mojo::UserAgent)...\n";
    $unscored = [
        {
            id       => 0,
            ticker   => 'CEG',
            theme    => 'Data Center Power, Grid & Political Friction',
            headline => 'FERC approves landmark behind-the-meter nuclear interconnection tariff for hyperscale data center',
            summary  => 'PJM interconnection approval paves way for 1.2GW co-located nuclear power generation without grid queue delays.',
        }
    ];
}

if (!@$unscored) {
    print "[evaluate_catalysts] No unscored catalyst events found in ledger.\n";
    $dbh->disconnect;
    exit 0;
}

print "[evaluate_catalysts] Evaluating " . scalar(@$unscored) . " catalyst event(s) with Gemini API ($model)...\n";

my $ua = Mojo::UserAgent->new;
$ua->inactivity_timeout(20);
$ua->connect_timeout(10);
my $endpoint = "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$api_key";

for my $event (@$unscored) {
    my $prompt = qq{
You are the catalyst evaluation agent for an investment portfolio governed strictly by specs/03-catalyst-weights.md.
Score the following candidate catalyst on a scale of 1 to 10:
- 1-3 (Noise): Routine commentary, recycled headlines, unconfirmed rumors -> Ignore
- 4-6 (Watchlist): Material development with unclear timing or priced-in consensus -> Monitor only
- 7-8 (Actionable): Verified fundamental, regulatory, or supply-chain shift with 1-6 week repricing window -> Standard position
- 9-10 (High Conviction): Major structural shock, policy reversal, or bottleneck inflection -> Max position sizing

Themes to weight:
1. AI Silicon & Supply Chain (High): GPU scrutiny, hyperscaler custom ASIC capex, CoWoS/HBM packaging bottlenecks.
2. Data Center Power, Grid & Political Friction (High): Nuclear IPPs, behind-the-meter agreements, FERC rulings, interconnection delays.
3. Macro & Rate Sensitivity (Medium): 10Y Treasury yield spikes, inflation prints, Fed rate trajectory.

Respond strictly in valid JSON matching this schema:
{"ticker": "$event->{ticker}", "score": integer 1-10, "theme": "$event->{theme}", "rationale": "one concise sentence explaining why this score was assigned according to the rubric"}

Candidate Event:
Ticker: $event->{ticker}
Theme: $event->{theme}
Headline: $event->{headline}
Summary: $event->{summary}
};

    my $payload = {
        contents => [
            { parts => [ { text => $prompt } ] }
        ],
        generationConfig => {
            responseMimeType => "application/json"
        }
    };

    my $tx = $ua->post($endpoint => json => $payload);

    if (!$tx->result->is_success) {
        warn sprintf("[evaluate_catalysts] API call failed for %s (%d): %s\n",
            $event->{ticker}, $tx->result->code, $tx->result->body);
        next;
    }

    my $raw_text = $tx->result->json->{candidates}[0]{content}{parts}[0]{text} // '';
    my $parsed;
    eval { $parsed = decode_json($raw_text); };

    if ($parsed && ref $parsed eq 'HASH') {
        my $score     = $parsed->{score} // 5;
        my $theme     = $parsed->{theme} // $event->{theme};
        my $rationale = $parsed->{rationale} // 'Evaluated by Gemini model';

        printf "[evaluate_catalysts] [%s] Score: %d/10 | Theme: %s\n", $event->{ticker}, $score, $theme;
        printf "  Rationale: %s\n", $rationale;

        if (!$dry_run && $event->{id} > 0) {
            update_catalyst_score($dbh, $event->{id}, $score, $theme, $rationale);
        }
    } else {
        warn "[evaluate_catalysts] Failed to parse JSON response for $event->{ticker}: $raw_text\n";
    }
}

$dbh->disconnect;
print "[evaluate_catalysts] Catalyst evaluation completed successfully.\n";

__END__

=head1 NAME

evaluate_catalysts.pl - Score ingested news against the 1-10 rubric via Gemini REST API

=head1 SYNOPSIS

evaluate_catalysts.pl [options]

 Options:
   --dry-run       Verify scoring logic without committing changes to database
   --model=NAME    Gemini model name (default: gemini-2.5-flash)
   --help, -h      Show this help message

=cut
