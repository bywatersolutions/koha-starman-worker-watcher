use Modern::Perl;

use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX      qw(strftime);
use Path::Tiny qw(path);

my $log_root     = tempdir( CLEANUP => 1 );
my $capture_root = tempdir( CLEANUP => 1 );

# _base_dir / _output_dir read these at call time.
$ENV{KSWW_LOG_ROOT}    = $log_root;
$ENV{KSWW_CAPTURE_DIR} = $capture_root;

require Koha::StarmanWorkerWatcher::Logs;

my $instance  = 'mylib';
my $inst_dir  = path( $log_root, $instance );
$inst_dir->mkpath;

my $kill_time = 1776038400;    # 2026-04-17 12:00:00 UTC
my $pid       = 4242;
my $other_pid = 9999;

# Apache/Plack combined access log: explicit TZ offset, so UTC is fine
# regardless of the host's TZ.
my $access_in_ts  = strftime( '[%d/%b/%Y:%H:%M:%S +0000]', gmtime( $kill_time + 30 ) );
my $access_out_ts = strftime( '[%d/%b/%Y:%H:%M:%S +0000]', gmtime( $kill_time + 120 ) );

$inst_dir->child('opac-access.log')->spew_utf8(
    join(
        "\n",
        qq{192.0.2.1 - - $access_in_ts "GET /cgi-bin/koha/opac-search.pl HTTP/1.1" 502 0 "-" "UA"},
        qq{192.0.2.1 - - $access_in_ts "GET /ok HTTP/1.1" 200 1024 "-" "UA"},
        qq{192.0.2.1 - - $access_out_ts "GET /too-late HTTP/1.1" 502 0 "-" "UA"},
    ) . "\n"
);

$inst_dir->child('intranet-access.log')->spew_utf8(
    qq{10.0.0.5 - kyle $access_in_ts "POST /cgi-bin/koha/reports/guided_reports.pl HTTP/1.1" 502 0 "-" "UA"\n}
);

$inst_dir->child('plack.log')->spew_utf8('');

# Koha log4perl output: `[%d] [%P] [%p] %m`. pid_match grepping for
# `[<pid>]` should pick up our worker's lines only. Mix in another
# PID's lines (which must be excluded) and an Apache-format error
# line (which uses `[pid N:tid N]` and must also be excluded).
$inst_dir->child('plack-intranet-error.log')->spew_utf8(
    join(
        "\n",
        qq{[2026/04/17 11:59:30] [$pid] [WARN] Argument isn't numeric at C4/Reserves.pm line 42.},
        qq{[2026/04/17 12:00:15] [$pid] [ERROR] Cannot connect to broker at BackgroundJob.pm line 100.},
        qq{[2026/04/17 12:00:15] [$other_pid] [WARN] some other worker's log line},
    ) . "\n"
);

$inst_dir->child('plack-opac-error.log')->spew_utf8(
    qq{[2026/04/17 12:00:00] [$pid] [WARN] Use of uninitialized value at opac-user.pl line 98.\n}
);

$inst_dir->child('plack-api-error.log')->spew_utf8('');

$inst_dir->child('api-error.log')->spew_utf8(
    qq{[2026/04/17 12:00:00] [$pid] [WARN] api warning for our worker\n}
);

# opac-error.log / intranet-error.log receive BOTH Apache's own error
# output (uses `[pid N:tid N]`, different syntax) and Koha log4perl
# output (uses `[N]`). pid_match must catch the log4perl line and
# reject the Apache lines even though they also reference digits.
$inst_dir->child('opac-error.log')->spew_utf8(
    join(
        "\n",
        qq{[Fri Apr 17 12:00:00.000000 2026] [proxy:error] [pid $pid:tid $pid] AH00898: proxy error},
        qq{[2026/04/17 12:00:00] [$pid] [WARN] log4perl line from our worker},
    ) . "\n"
);

$inst_dir->child('intranet-error.log')->spew_utf8('');

# plack-error.log is unstructured; tail should just return last N lines.
$inst_dir->child('plack-error.log')
    ->spew_utf8( join( "\n", map { "lifecycle line $_" } 1 .. 30 ) . "\n" );

my $logs   = Koha::StarmanWorkerWatcher::Logs->new;
my $result = $logs->collect(
    pid       => $pid,
    instance  => $instance,
    signal    => 'TERM',
    kill_time => $kill_time,
);

ok( $result->{ok}, 'collect returned ok' );

my @am = @{ $result->{access_matches} };
is( scalar @am, 2, 'two in-window 502s across access logs' );
like( join( "\n", @am ), qr/opac-access\.log.*opac-search/,            'opac 502 surfaced' );
like( join( "\n", @am ), qr/intranet-access\.log.*guided_reports/,     'intranet 502 surfaced' );
unlike( join( "\n", @am ), qr{ HTTP/1\.1" 200 },  '200s are filtered out' );
unlike( join( "\n", @am ), qr/too-late/,          'out-of-window 502 excluded' );

my %by = map { $_->{name} => $_ } @{ $result->{files} };

subtest 'access log filtering' => sub {
    is( scalar @{ $by{'opac-access.log'}{lines} },     1, 'opac-access.log: one 502 kept' );
    is( scalar @{ $by{'intranet-access.log'}{lines} }, 1, 'intranet-access.log: one 502 kept' );
    is( scalar @{ $by{'plack.log'}{lines} },           0, 'plack.log empty => no matches' );
};

subtest 'pid_match picks up log4perl lines for the killed PID' => sub {
    is( scalar @{ $by{'plack-intranet-error.log'}{lines} }, 2,
        'plack-intranet-error.log: keeps our two PID lines, drops other-PID line' );
    is( scalar @{ $by{'plack-opac-error.log'}{lines} },     1, 'plack-opac-error.log: one match' );
    is( scalar @{ $by{'plack-api-error.log'}{lines} },      0, 'plack-api-error.log: empty' );
    is( scalar @{ $by{'api-error.log'}{lines} },            1, 'api-error.log: one match' );

    my @other = grep { /\[$other_pid\]/ } @{ $by{'plack-intranet-error.log'}{lines} };
    is( scalar @other, 0, "other worker's PID does not leak into results" );
};

subtest 'pid_match rejects Apache [pid N:tid N] syntax' => sub {
    my @kept = @{ $by{'opac-error.log'}{lines} };
    is( scalar @kept, 1, 'opac-error.log: only the log4perl line kept' );
    like( $kept[0], qr/log4perl line from our worker/, 'correct line kept' );
    unlike( join( "\n", @kept ), qr/proxy:error/, 'Apache proxy error line excluded' );
};

subtest 'tail filter on plack-error.log' => sub {
    my @lines = @{ $by{'plack-error.log'}{lines} };
    ok( scalar @lines > 0 && scalar @lines <= 1000, 'tail returns up to TAIL_LINES lines' );
    is( $lines[-1], 'lifecycle line 30', 'last line is the newest' );
};

ok( -f $result->{path}, 'bundle file written' );
my $body = path( $result->{path} )->slurp_utf8;
like( $body, qr/opac-search/, 'bundle includes opac 502 line' );
my $expected_date = strftime( '%Y-%m-%d', gmtime($kill_time) );
like( $body, qr/\Qkill_time=$expected_date\E/, 'bundle header has kill_time' );

subtest 'path traversal in instance name is rejected' => sub {
    my $bad = $logs->collect( pid => 1, instance => '../etc' );
    ok( !$bad->{ok}, 'rejected' );
    like( $bad->{error}, qr/invalid instance/, 'error message' );
};

subtest 'missing files render as (file not found) in the bundle' => sub {
    my $empty_instance = 'noperm';
    path( $log_root, $empty_instance )->mkpath;    # dir exists, no files
    my $r = $logs->collect(
        pid       => 9,
        instance  => $empty_instance,
        kill_time => $kill_time,
    );
    ok( $r->{ok}, 'ok even when all files missing' );
    is( scalar @{ $r->{access_matches} }, 0, 'no access matches' );
    like( path( $r->{path} )->slurp_utf8, qr/\Q(file not found)\E/,
        'bundle marks missing files' );
};

done_testing;
