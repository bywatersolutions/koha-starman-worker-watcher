use Modern::Perl;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use FakeProc;
use Koha::StarmanWorkerWatcher;

# Short-circuit the poll loop so run() executes the startup block and
# immediately exits.
{
    no warnings 'redefine';
    *Koha::StarmanWorkerWatcher::scan = sub { $_[0]->{_stop} = 1 };
}

package FakeSlack;
sub new { bless { sent => [], notices => [] }, shift }
sub send_alert  { my ($s,$a)=@_; push @{$s->{sent}},    $a; return { success=>1 } }
sub send_notice { my ($s,$t)=@_; push @{$s->{notices}}, $t; return { success=>1 } }
sub sent        { $_[0]->{sent} }
sub notices     { $_[0]->{notices} }

package main;

sub build_watcher {
    my (%cfg_slack) = @_;
    my $config = {
        poll_interval_seconds     => 10,
        runtime_threshold_seconds => 300,
        memory_threshold_mb       => 1024,
        ignore_scripts            => [],
        ignore_instances          => [],
        capture                   => { enabled => 0 },
        slack                     => { %cfg_slack },
    };
    my $slack = FakeSlack->new;
    my $w     = Koha::StarmanWorkerWatcher->new(
        config   => $config,
        slack    => $slack,
        hostname => 'koha01.test',
        log_cb   => sub { },
    );
    return ( $w, $slack );
}

# 1) webhook_url set -> startup notice is sent
{
    my ( $w, $slack ) = build_watcher( webhook_url => 'https://hooks.example/T/B/X' );
    $w->run;
    is( scalar @{ $slack->notices }, 1, 'notice sent when webhook_url is set' );
    like(
        $slack->notices->[0],
        qr/koha-starman-worker-watcher started on koha01\.test/,
        'notice mentions hostname'
    );
    like(
        $slack->notices->[0],
        qr/runtime>300s AND memory>1024MiB/,
        'notice mentions thresholds with AND'
    );
    is( scalar @{ $slack->sent }, 0, 'no alert on startup' );
}

# 2) webhook_url empty -> no notice at all
{
    my ( $w, $slack ) = build_watcher( webhook_url => '' );
    $w->run;
    is( scalar @{ $slack->notices }, 0, 'no notice when webhook_url is empty' );
}

# 3) webhook_url absent entirely -> no notice
{
    my ( $w, $slack ) = build_watcher();
    $w->run;
    is( scalar @{ $slack->notices }, 0, 'no notice when slack has no webhook_url key' );
}

done_testing;
