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

# Build a watcher whose now_cb returns a scalar we can advance between
# scans to simulate dwell time.
sub make_watcher {
    my (%args) = @_;
    my $kills = [];
    my $slack = FakeSlack->new;
    my $w     = Koha::StarmanWorkerWatcher->new(
        config   => $args{config},
        slack    => $slack,
        now_cb   => $args{now_cb},
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

subtest 'no kill thresholds set: alert fires but no kills' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 4000, pid => 4001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds => 10,
        memory_threshold_mb   => 500,
        ignore_scripts        => [],
        ignore_instances      => [],
        capture               => { enabled => 0 },
        slack                 => { webhook_url => 'http://example/' },
    };

    my $now = 1700000000 + 7200;
    my ( $w, $slack, $kills ) = make_watcher(
        config => $config,
        now_cb => sub { $now },
    );
    $w->scan;
    is( scalar @$kills,           0, 'no kill_* config => no signals sent' );
    is( scalar @{ $slack->sent }, 1, 'alert still fires' );
};

subtest 'dwell-based kill: TERM after threshold, KILL on next scan' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 5000, pid => 5001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds          => 10,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        ignore_scripts                 => [],
        ignore_instances               => [],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    my $now = 1700000000 + 7200;
    my ( $w, $slack, $kills ) = make_watcher(
        config => $config,
        now_cb => sub { $now },
    );

    # First scan: worker crosses memory_threshold_mb, dwell clock starts
    # at $now. Dwell = 0, not > 1800 yet, so no kill.
    $w->scan;
    is( scalar @$kills, 0, 'dwell clock just started: no kill on first scan' );

    # Advance time by 30 minutes + 1s so dwell clears the 1800s threshold.
    $now += 1801;
    $w->scan;
    is( scalar @$kills, 1, 'dwell > kill_runtime_threshold_seconds => SIGTERM' );
    is_deeply( $kills->[0], [ 'TERM', 5001 ], 'TERM sent first' );
    like( $slack->notices->[-1], qr/SIGTERM/, 'slack notice for TERM' );

    # Next scan: still over, sigterm_sent=1 => escalate to SIGKILL.
    $now += 10;
    $w->scan;
    is( scalar @$kills, 2, 'second scan still over => escalate to SIGKILL' );
    is_deeply( $kills->[1], [ 'KILL', 5001 ], 'KILL sent on escalation' );
    like( $slack->notices->[-1], qr/SIGKILL/, 'slack notice for KILL' );

    $now += 10;
    $w->scan;
    is( scalar @$kills, 2, 'no further signals after SIGKILL' );
};

subtest 'dwell clock resets if memory drops below threshold' => sub {
    my $fp = FakeProc->new;
    $fp->activate;

    # Start OVER threshold so memory_over_since is set.
    seed_worker( $fp, master_pid => 5100, pid => 5101, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds          => 10,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        ignore_scripts                 => [],
        ignore_instances               => [],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    my $now = 1700000000 + 7200;
    my ( $w, undef, $kills ) = make_watcher(
        config => $config,
        now_cb => sub { $now },
    );

    $w->scan;    # dwell starts at t=0

    # Worker drops below threshold ten minutes later.
    $now += 600;
    seed_worker( $fp, master_pid => 5100, pid => 5101, rss_kb => 200_000 );
    $w->scan;    # dwell resets

    # Worker climbs back over threshold. Only twenty minutes of dwell
    # this time (below the 1800s kill threshold).
    $now += 600;
    seed_worker( $fp, master_pid => 5100, pid => 5101, rss_kb => 5_000_000 );
    $w->scan;    # dwell starts fresh at this $now

    $now += 1200;   # only 20 minutes of dwell
    $w->scan;
    is( scalar @$kills, 0, 'dwell reset after dip: 20 min not enough to kill' );

    # Enough more time to push the fresh dwell past 1800s.
    $now += 700;    # now 1900s of dwell since the reset
    $w->scan;
    is( scalar @$kills, 1, 'fresh dwell now past threshold: kill fires' );
    is_deeply( $kills->[0], [ 'TERM', 5101 ], 'TERM sent' );
};

subtest 'only kill_memory set: no dwell, kills on current RSS alone' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 6000, pid => 6001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds    => 10,
        memory_threshold_mb      => 500,
        kill_memory_threshold_mb => 4096,
        ignore_scripts           => [],
        ignore_instances         => [],
        capture                  => { enabled => 0 },
        slack                    => { webhook_url => 'http://example/' },
    };

    my $now = 1700000000 + 10;    # young worker
    my ( $w, undef, $kills ) = make_watcher(
        config => $config,
        now_cb => sub { $now },
    );
    $w->scan;
    is( scalar @$kills, 1, 'kill_memory-only fires immediately when over current RSS bar' );
    is_deeply( $kills->[0], [ 'TERM', 6001 ], 'TERM sent' );
};

subtest 'kill_memory gate blocks kill when current RSS is below it' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 7000, pid => 7001, rss_kb => 700_000 );    # ~683 MiB

    my $config = {
        poll_interval_seconds          => 10,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        kill_memory_threshold_mb       => 4096,
        ignore_scripts                 => [],
        ignore_instances               => [],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    my $now = 1700000000;
    my ( $w, undef, $kills ) = make_watcher(
        config => $config,
        now_cb => sub { $now },
    );
    $w->scan;
    $now += 3600;    # plenty of dwell
    $w->scan;
    is( scalar @$kills, 0,
        'dwell satisfied but current RSS below kill_memory_threshold_mb: no kill'
    );
};

subtest 'ignore_instances suppresses kill' => sub {
    my $fp = FakeProc->new;
    $fp->activate;
    seed_worker( $fp, master_pid => 9000, pid => 9001, rss_kb => 5_000_000 );

    my $config = {
        poll_interval_seconds          => 10,
        memory_threshold_mb            => 500,
        kill_runtime_threshold_seconds => 1800,
        ignore_scripts                 => [],
        ignore_instances               => ['mylib'],
        capture                        => { enabled => 0 },
        slack                          => { webhook_url => 'http://example/' },
    };

    my $now = 1700000000;
    my ( $w, undef, $kills ) = make_watcher(
        config => $config,
        now_cb => sub { $now },
    );
    $w->scan;
    $now += 3600;
    $w->scan;
    is( scalar @$kills, 0, 'ignored instance is not killed even after long dwell' );
};

done_testing;
