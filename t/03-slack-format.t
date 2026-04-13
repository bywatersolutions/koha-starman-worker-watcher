use Modern::Perl;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Koha::StarmanWorkerWatcher::Slack;

my $slack = Koha::StarmanWorkerWatcher::Slack->new( dry_run => 1 );

my $alert = {
    reason          => 'runtime',
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

like( $text, qr/Koha worker exceeded runtime threshold/, 'mentions reason' );
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

done_testing;
