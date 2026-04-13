use Modern::Perl;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use FakeProc;
use Koha::StarmanWorkerWatcher::Proc;

my $fp = FakeProc->new;
$fp->activate;

$fp->add_process(
    pid     => 1000,
    ppid    => 1,
    comm    => 'starman',
    cmdline => [ '/usr/bin/perl', '/usr/bin/starman', 'master', '--workers', '4', '/etc/koha/sites/mylib/plack.psgi' ],
);

$fp->add_process(
    pid     => 1001,
    ppid    => 1000,
    comm    => 'starman',
    cmdline => [ 'starman', 'worker', '--max-requests', '50' ],
    rss_kb  => 50_000,
    swap_kb => 0,
    env     => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
);

$fp->add_process(
    pid     => 1002,
    ppid    => 1000,
    comm    => 'starman',
    cmdline => ['/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl'],
    rss_kb  => 1_200_000,
    swap_kb => 64_000,
    starttime_ticks => 500,
    env     => { KOHA_CONF => '/etc/koha/sites/mylib/koha-conf.xml' },
);

$fp->add_process(
    pid     => 2000,
    ppid    => 1,
    comm    => 'perl',
    cmdline => [ 'perl', '/tmp/unrelated.pl' ],
);

my @pids = Koha::StarmanWorkerWatcher::Proc::list_pids();
is_deeply(
    [ sort { $a <=> $b } @pids ],
    [ 1000, 1001, 1002, 2000 ],
    'list_pids finds all fake pids'
);

my $idle = Koha::StarmanWorkerWatcher::Proc::worker_info(1001);
ok( Koha::StarmanWorkerWatcher::Proc::is_starman_worker($idle), 'idle worker detected as starman worker' );
is( $idle->{script},   '',      'idle worker has empty script' );
is( $idle->{idle},     1,       'idle worker marked idle' );
is( $idle->{instance}, 'mylib', 'instance parsed from KOHA_CONF env' );
is( $idle->{rss_kb},   50_000,  'rss parsed from VmRSS' );

my $active = Koha::StarmanWorkerWatcher::Proc::worker_info(1002);
ok( Koha::StarmanWorkerWatcher::Proc::is_starman_worker($active), 'active worker detected as starman worker (parent is master)' );
is(
    $active->{script},
    '/usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl',
    'script captured from cmdline'
);
is( $active->{idle},     0,         'active worker not marked idle' );
is( $active->{instance}, 'mylib',   'instance parsed for active worker' );
is( $active->{rss_kb},   1_200_000, 'active worker rss' );
is( $active->{swap_kb},  64_000,    'active worker swap' );

my $unrelated = Koha::StarmanWorkerWatcher::Proc::worker_info(2000);
ok(
    !Koha::StarmanWorkerWatcher::Proc::is_starman_worker($unrelated),
    'unrelated perl process not flagged'
);

is(
    Koha::StarmanWorkerWatcher::Proc::btime(),
    1700000000,
    'btime parsed from /proc/stat'
);

done_testing;
