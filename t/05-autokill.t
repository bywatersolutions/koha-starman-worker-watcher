use Modern::Perl;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use FakeProc;
use Koha::StarmanWorkerWatcher;

# Stub capture so the evaluator doesn't try to spawn strace, and stub
# log collection so it doesn't touch /var/log/koha on the host.
{
    no warnings 'redefine';
    *Koha::StarmanWorkerWatcher::Capture::capture = sub {
        return { ok => 1, path => '', tail => '' };
    };
    *Koha::StarmanWorkerWatcher::Logs::collect = sub {
        return { ok => 1, path => '', access_matches => [] };
    };
}

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

sub make_watcher {
    my (%args) = @_;
    my $kills  = [];
    my $slack  = FakeSlack->new;
    my $w      = Koha::StarmanWorkerWatcher->new(
        config   => $args{config},
        slack    => $slack,
        now_cb   => sub { $args{now} },
        log_cb   => sub { },
        kill_cb  => sub { my ( $sig, $pid ) = @_; push @$kills, [ $sig, $pid ]; return 1; },
        sleep_cb => sub { },
        alive_cb => sub { 0 },
    );
    return ( $w, $slack, $kills );
}

sub seed_worker {
    my ( $fp, %p ) = @_;
    $fp->add_process(
        pid     => $p{master_pid},
        ppid    => 1,
        comm    => 'starman',
        cmdline => [ 'starman', 'master', '/etc/koha/sites/mylib/plack.psgi' ],
    );
    $fp->add_process(
        pid             => $p{pid},
        ppid            => $p{master_pid},
        comm            => 'starman',
        cmdline         => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
        rss_kb          => $p{rss_kb},
        swap_kb         => 0,
        starttime_ticks => 0,
        env             => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
    );
}

subtest 'no kill thresholds set: no kills' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 4000, pid => 4001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds     => 10,
        runtime_threshold_seconds => 60,
        memory_threshold_mb       => 500,
        ignore_scripts            => [],
        ignore_instances          => [],
        capture                   => { enabled => 0 },
        slack                     => { webhook_url => 'http://example/' },
    };

    my ( $w, $slack, $kills ) = make_watcher( config => $config, now => 1700000000 + 7200 );
    $w->scan;
    is( scalar @$kills, 0, 'no kill_* config => no signals sent' );
    is( scalar @{ $slack->sent }, 1, 'alert still fires' );
};

subtest 'both kill thresholds set: TERM then KILL on next scan' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 5000, pid => 5001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds          => 10,
        runtime_threshold_seconds      => 60,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        kill_memory_threshold_mb       => 4096,
        ignore_scripts                 => [],
        ignore_instances               => [],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    my ( $w, $slack, $kills ) = make_watcher( config => $config, now => 1700000000 + 7200 );

    $w->scan;
    is( scalar @$kills, 1, 'first scan over-kill-threshold => SIGTERM only' );
    is_deeply( $kills->[0], [ 'TERM', 5001 ], 'TERM sent first' );
    like( $slack->notices->[-1], qr/SIGTERM/, 'slack notice for TERM' );

    $w->scan;
    is( scalar @$kills, 2, 'second scan still over => escalate to SIGKILL' );
    is_deeply( $kills->[1], [ 'KILL', 5001 ], 'KILL sent on escalation' );
    like( $slack->notices->[-1], qr/SIGKILL/, 'slack notice for KILL' );

    $w->scan;
    is( scalar @$kills, 2, 'no further signals after SIGKILL' );
};

subtest 'only kill_memory set: kills on memory alone' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 6000, pid => 6001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds     => 10,
        runtime_threshold_seconds => 60,
        memory_threshold_mb       => 500,
        kill_memory_threshold_mb  => 4096,
        ignore_scripts            => [],
        ignore_instances          => [],
        capture                   => { enabled => 0 },
        slack                     => { webhook_url => 'http://example/' },
    };

    # Young worker (10s), well under any reasonable runtime kill bar.
    my ( $w, $slack, $kills ) = make_watcher( config => $config, now => 1700000000 + 10 );
    $w->scan;
    is( scalar @$kills, 1, 'memory-only kill threshold fires regardless of runtime' );
    is_deeply( $kills->[0], [ 'TERM', 6001 ], 'TERM sent' );
};

subtest 'only kill_runtime set: kills on runtime alone' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 7000, pid => 7001, rss_kb => 100_000 );    # tiny

    my $config = {
        poll_interval_seconds          => 10,
        runtime_threshold_seconds      => 60,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        ignore_scripts                 => [],
        ignore_instances               => [],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    my ( $w, $slack, $kills ) = make_watcher( config => $config, now => 1700000000 + 7200 );
    $w->scan;
    is( scalar @$kills, 1, 'runtime-only kill threshold fires regardless of memory' );
    is_deeply( $kills->[0], [ 'TERM', 7001 ], 'TERM sent' );
};

subtest 'kill thresholds not exceeded: no kills' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 8000, pid => 8001, rss_kb => 700_000 );    # ~683 MiB

    my $config = {
        poll_interval_seconds          => 10,
        runtime_threshold_seconds      => 60,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        kill_memory_threshold_mb       => 4096,
        ignore_scripts                 => [],
        ignore_instances               => [],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    # Memory under kill_memory, runtime over both alert and kill_runtime.
    my ( $w, undef, $kills ) = make_watcher( config => $config, now => 1700000000 + 7200 );
    $w->scan;
    is( scalar @$kills, 0, 'AND logic: not all set thresholds met => no kill' );
};

subtest 'ignore_instances suppresses kill' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 9000, pid => 9001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds          => 10,
        runtime_threshold_seconds      => 60,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        kill_memory_threshold_mb       => 4096,
        ignore_scripts                 => [],
        ignore_instances               => ['mylib'],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    my ( $w, undef, $kills ) = make_watcher( config => $config, now => 1700000000 + 7200 );
    $w->scan;
    is( scalar @$kills, 0, 'ignored instance is not killed' );
};

done_testing;
