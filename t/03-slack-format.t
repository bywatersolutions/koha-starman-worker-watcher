use Modern::Perl;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Koha::StarmanWorkerWatcher::Slack;

my $slack = Koha::StarmanWorkerWatcher::Slack->new( dry_run => 1 );

my $alert = {
    reason          => 'runtime and memory thresholds',
    instance        => 'mylib',
    pid             => 12345,
    script          => '/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl',
    runtime_seconds => 3725,
    rss_kb          => 1_048_576,
    swap_kb         => 262_144,
    host            => 'koha01',
    capture_tail    => "line a\nline b\n",
};

my $text = $slack->format_alert($alert);

like( $text, qr/Koha worker exceeded runtime and memory thresholds/, 'mentions reason' );
like( $text, qr/Instance: mylib/,  'instance line' );
like( $text, qr/PID: 12345/,       'pid line' );
like( $text, qr{Script: /usr/share/koha/intranet/cgi-bin/reports/guided_reports\.pl}, 'script line' );
like( $text, qr/Runtime: 01:02:05/, 'runtime formatted hh:mm:ss' );
like( $text, qr/RSS: 1024\.0 MiB/,  'rss in MiB' );
like( $text, qr/Swap: 256\.0 MiB/,  'swap in MiB' );
like( $text, qr/Host: koha01/,      'host line' );
like( $text, qr/```\nline a\nline b/, 'capture tail attached as code block' );

my $idle_alert = { %$alert, script => '' };
like( Koha::StarmanWorkerWatcher::Slack->new->format_alert($idle_alert),
    qr/Script: \(idle\)/, 'empty script rendered as (idle)' );

# Log-only mode: enabled => 0 must never touch HTTP, even if webhook_url
# is set.
{
    package FakeHttp;
    sub new  { bless { calls => 0 }, shift }
    sub post { my $self = shift; $self->{calls}++; return { success => 1, status => 200 } }
}
my $http       = FakeHttp->new;
my $log_only   = Koha::StarmanWorkerWatcher::Slack->new(
    enabled     => 0,
    webhook_url => 'http://should.not.be.called/',
    http        => $http,
);
my $captured = '';
{
    local *STDOUT;
    open STDOUT, '>', \$captured or die;
    my $res = $log_only->send_alert($alert);
    ok( $res->{success},  'log-only send returns success' );
    ok( $res->{log_only}, 'log-only flag set on result' );
}
is( $http->{calls}, 0, 'log-only mode never calls HTTP post' );
like( $captured, qr/\[log-only slack\]/, 'log-only mode writes tagged line to stdout' );
like( $captured, qr/Instance: mylib/,    'log-only mode writes full alert text' );

done_testing;
