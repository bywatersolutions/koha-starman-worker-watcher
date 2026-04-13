use Modern::Perl;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use FakeProc;
use Koha::StarmanWorkerWatcher;

# Stub out the capture module so the evaluator doesn't try to spawn strace
# against our fake PIDs.
{
    no warnings 'redefine';
    *Koha::StarmanWorkerWatcher::Capture::capture = sub {
        return { ok => 1, path => '', tail => '' };
    };
}

# Capture Slack payloads instead of POSTing them.
package FakeSlack;
sub new  { bless { sent => [] }, shift }
sub send_alert {
    my ( $self, $alert ) = @_;
    push @{ $self->{sent} }, $alert;
    return { success => 1 };
}
sub sent { $_[0]->{sent} }

package main;

my $fp = FakeProc->new;
$fp->activate;

# Active long-running worker
$fp->add_process(
    pid     => 2001,
    ppid    => 1900,
    comm    => 'starman',
    cmdline => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
    rss_kb  => 200_000,    # well under threshold
    starttime_ticks => 0,    # start at btime, i.e. 1700000000
    env => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
);

# starman master parent so is_starman_worker returns true
$fp->add_process(
    pid     => 1900,
    ppid    => 1,
    comm    => 'starman',
    cmdline => [ 'starman', 'master', '/etc/koha/sites/mylib/plack.psgi' ],
);

my $config = {
    poll_interval_seconds     => 10,
    runtime_threshold_seconds => 60,
    memory_threshold_mb       => 500,
    ignore_scripts            => [],
    ignore_instances          => [],
    capture                   => { enabled => 0 },
    slack                     => { webhook_url => 'http://example/' },
};

my $slack = FakeSlack->new;

# Pin "now" to 1700000000 + 120 so runtime = 120s (> 60s threshold).
my $fake_now = 1700000000 + 120;

my $watcher = Koha::StarmanWorkerWatcher->new(
    config => $config,
    slack  => $slack,
    now_cb => sub { $fake_now },
    log_cb => sub { },
);

$watcher->scan;
is( scalar @{ $slack->sent }, 1, 'one alert on first scan over runtime threshold' );
is( $slack->sent->[0]{reason},   'runtime', 'reason is runtime' );
is( $slack->sent->[0]{pid},      2001,      'alert pid' );
is( $slack->sent->[0]{instance}, 'mylib',   'alert instance' );

$watcher->scan;
is( scalar @{ $slack->sent }, 1, 'second scan does not re-alert same pid' );

# Bump memory past threshold and re-scan — should fire the memory alert once.
$fp->add_process(
    pid             => 2001,
    ppid            => 1900,
    comm            => 'starman',
    cmdline         => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
    rss_kb          => 700_000,    # 683 MiB, over threshold
    swap_kb         => 10_000,
    starttime_ticks => 0,
    env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
);

$watcher->scan;
is( scalar @{ $slack->sent }, 2, 'memory alert fires on a subsequent scan' );
is( $slack->sent->[1]{reason}, 'memory', 'second alert reason is memory' );

$watcher->scan;
is( scalar @{ $slack->sent }, 2, 'memory alert does not repeat' );

done_testing;
