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

sub base_config {
    return {
        poll_interval_seconds => 10,
        memory_threshold_mb   => 500,
        ignore_scripts        => [],
        ignore_instances      => [],
        capture               => { enabled => 0 },
        slack                 => { webhook_url => 'http://example/' },
    };
}

subtest 'memory under threshold: no alert' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    $fp->add_process(
        pid     => 1900,
        ppid    => 1,
        comm    => 'starman',
        cmdline => [ 'starman', 'master', '/etc/koha/sites/mylib/plack.psgi' ],
    );
    $fp->add_process(
        pid             => 2001,
        ppid            => 1900,
        comm            => 'starman',
        cmdline         => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
        rss_kb          => 200_000,    # ~195 MiB, under 500 MiB
        starttime_ticks => 0,
        env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
    );

    my $slack = FakeSlack->new;
    my $w     = Koha::StarmanWorkerWatcher->new(
        config => base_config(),
        slack  => $slack,
        now_cb => sub { 1700000000 + 120 },
        log_cb => sub { },
    );
    $w->scan;
    is( scalar @{ $slack->sent }, 0, 'under-memory worker does not alert' );
};

subtest 'memory over threshold: alert fires' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    $fp->add_process(
        pid     => 1900,
        ppid    => 1,
        comm    => 'starman',
        cmdline => [ 'starman', 'master', '/etc/koha/sites/mylib/plack.psgi' ],
    );
    $fp->add_process(
        pid             => 2001,
        ppid            => 1900,
        comm            => 'starman',
        cmdline         => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
        rss_kb          => 700_000,    # ~683 MiB, over 500 MiB
        swap_kb         => 10_000,
        starttime_ticks => 0,
        env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
    );

    my $slack = FakeSlack->new;
    my $w     = Koha::StarmanWorkerWatcher->new(
        config => base_config(),
        slack  => $slack,
        now_cb => sub { 1700000000 + 10 },    # young worker, alerts immediately
        log_cb => sub { },
    );
    $w->scan;
    is( scalar @{ $slack->sent }, 1, 'over-memory worker alerts on first scan' );
    is( $slack->sent->[0]{reason},   'memory threshold', 'alert reason' );
    is( $slack->sent->[0]{pid},      2001,               'alert pid' );
    is( $slack->sent->[0]{instance}, 'mylib',            'alert instance' );

    $w->scan;
    is( scalar @{ $slack->sent }, 1, 'alert is one-shot per PID lifetime' );
};

subtest 'worker with bare starman proctitle still alerts on memory' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    $fp->add_process(
        pid     => 1900,
        ppid    => 1,
        comm    => 'starman',
        cmdline => [ 'starman', 'master', '/etc/koha/sites/mylib/plack.psgi' ],
    );
    $fp->add_process(
        pid             => 2010,
        ppid            => 1900,
        comm            => 'starman',
        cmdline         => [ 'starman', 'worker', '--pidfile', '/run/koha.pid' ],
        rss_kb          => 1_200_000,
        starttime_ticks => 0,
        env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
    );

    my $slack = FakeSlack->new;
    my $w     = Koha::StarmanWorkerWatcher->new(
        config => base_config(),
        slack  => $slack,
        now_cb => sub { 1700000000 + 600 },
        log_cb => sub { },
    );
    $w->scan;
    is( scalar @{ $slack->sent },    1,       'bare-proctitle worker over memory alerts' );
    is( $slack->sent->[0]{script},   '',      'alert carries empty script' );
    is( $slack->sent->[0]{instance}, 'mylib', 'alert instance parsed' );
};

subtest 'ignore_scripts suppresses alert' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    $fp->add_process(
        pid     => 1900,
        ppid    => 1,
        comm    => 'starman',
        cmdline => [ 'starman', 'master', '/etc/koha/sites/mylib/plack.psgi' ],
    );
    $fp->add_process(
        pid             => 2020,
        ppid            => 1900,
        comm            => 'starman',
        cmdline         => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
        rss_kb          => 900_000,
        starttime_ticks => 0,
        env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
    );

    my $cfg = base_config();
    $cfg->{ignore_scripts} = ['guided_reports.pl'];

    my $slack = FakeSlack->new;
    my $w     = Koha::StarmanWorkerWatcher->new(
        config => $cfg,
        slack  => $slack,
        now_cb => sub { 1700000000 + 600 },
        log_cb => sub { },
    );
    $w->scan;
    is( scalar @{ $slack->sent }, 0, 'ignored script basename suppresses alert' );
};

done_testing;
