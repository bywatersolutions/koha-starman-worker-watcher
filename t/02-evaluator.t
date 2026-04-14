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
sub new { bless { sent => [], notices => [] }, shift }
sub send_alert {
    my ( $self, $alert ) = @_;
    push @{ $self->{sent} }, $alert;
    return { success => 1 };
}
sub send_notice {
    my ( $self, $text ) = @_;
    push @{ $self->{notices} }, $text;
    return { success => 1 };
}
sub sent    { $_[0]->{sent} }
sub notices { $_[0]->{notices} }

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
is(
    scalar @{ $slack->sent }, 0,
    'runtime-over-but-memory-under: AND logic, no alert'
);

# Bump memory past threshold so BOTH conditions are now true at the same sample.
$fp->add_process(
    pid             => 2001,
    ppid            => 1900,
    comm            => 'starman',
    cmdline         => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
    rss_kb          => 700_000,    # ~683 MiB, over threshold
    swap_kb         => 10_000,
    starttime_ticks => 0,
    env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
);

$watcher->scan;
is( scalar @{ $slack->sent }, 1, 'both conditions met: one combined alert' );
is(
    $slack->sent->[0]{reason},
    'runtime and memory thresholds',
    'combined reason in alert payload'
);
is( $slack->sent->[0]{pid},      2001,    'alert pid' );
is( $slack->sent->[0]{instance}, 'mylib', 'alert instance' );

$watcher->scan;
is( scalar @{ $slack->sent }, 1, 'combined alert does not repeat on next scan' );

# A PID whose memory is over but runtime is under should not alert.
my $young_now = 1700000000 + 10;    # 10s runtime, under 60s threshold
my $slack2    = FakeSlack->new;
my $fp2       = FakeProc->new;
$fp2->activate;
$fp2->add_process(
    pid     => 3100,
    ppid    => 3000,
    comm    => 'starman',
    cmdline => [ 'starman', 'master', '/etc/koha/sites/mylib/plack.psgi' ],
);
$fp2->add_process(
    pid             => 3101,
    ppid            => 3100,
    comm            => 'starman',
    cmdline         => ['/usr/share/koha/intranet/cgi-bin/circ/circulation.pl'],
    rss_kb          => 900_000,    # over memory threshold
    swap_kb         => 0,
    starttime_ticks => 0,
    env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
);
my $watcher2 = Koha::StarmanWorkerWatcher->new(
    config => $config,
    slack  => $slack2,
    now_cb => sub { $young_now },
    log_cb => sub { },
);
$watcher2->scan;
is(
    scalar @{ $slack2->sent }, 0,
    'memory-over-but-runtime-under: AND logic, no alert'
);

done_testing;
