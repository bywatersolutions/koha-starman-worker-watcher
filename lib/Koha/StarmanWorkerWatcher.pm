package Koha::StarmanWorkerWatcher;

use Modern::Perl;

use Sys::Hostname qw(hostname);
use YAML::XS      ();

use Koha::StarmanWorkerWatcher::Proc;
use Koha::StarmanWorkerWatcher::Slack;
use Koha::StarmanWorkerWatcher::Capture;

our $VERSION = '0.1.0';

sub new {
    my ( $class, %args ) = @_;

    my $config = $args{config}
        or die "config required\n";

    my $self = bless {
        config    => $config,
        hostname  => $args{hostname}  // hostname(),
        slack     => $args{slack}     // Koha::StarmanWorkerWatcher::Slack->new(
            webhook_url => $config->{slack}{webhook_url} // '',
            username    => $config->{slack}{username}    // 'koha-worker-watcher',
            icon_emoji  => $config->{slack}{icon_emoji}  // ':rotating_light:',
            dry_run     => $args{dry_run} // 0,
        ),
        capture   => $args{capture}   // Koha::StarmanWorkerWatcher::Capture->new(
            %{ $config->{capture} // {} }
        ),
        clock_ticks => Koha::StarmanWorkerWatcher::Proc::clock_ticks(),
        btime       => Koha::StarmanWorkerWatcher::Proc::btime(),
        tracked     => {},
        now_cb      => $args{now_cb} // sub { time() },
        log_cb      => $args{log_cb} // sub { print STDERR "@_\n" },
    }, $class;

    return $self;
}

sub load_config {
    my ( $class, $path ) = @_;
    open( my $fh, '<', $path ) or die "cannot open $path: $!\n";
    local $/;
    my $yaml = <$fh>;
    close($fh);

    my $parsed = YAML::XS::Load($yaml);
    $parsed //= {};

    $parsed->{poll_interval_seconds}     //= 10;
    $parsed->{runtime_threshold_seconds} //= 300;
    $parsed->{memory_threshold_mb}       //= 1024;
    $parsed->{ignore_scripts}            //= [];
    $parsed->{ignore_instances}          //= [];
    $parsed->{capture}                   //= {};
    $parsed->{slack}                     //= {};

    return $parsed;
}

sub log {
    my ( $self, $msg ) = @_;
    $self->{log_cb}->($msg);
    return;
}

sub scan {
    my ($self) = @_;

    my @pids = Koha::StarmanWorkerWatcher::Proc::list_pids();
    my %seen;

    for my $pid (@pids) {
        my $info = Koha::StarmanWorkerWatcher::Proc::worker_info($pid);
        next unless $info;
        next unless Koha::StarmanWorkerWatcher::Proc::is_starman_worker($info);

        $seen{$pid} = 1;
        $info->{start_epoch} = $self->_start_epoch( $info->{starttime_ticks} );
        $self->_track($info);
    }

    for my $pid ( keys %{ $self->{tracked} } ) {
        delete $self->{tracked}{$pid} unless $seen{$pid};
    }

    return;
}

sub _start_epoch {
    my ( $self, $ticks ) = @_;
    return 0 unless $self->{clock_ticks};
    return $self->{btime} + int( $ticks / $self->{clock_ticks} );
}

sub _track {
    my ( $self, $info ) = @_;

    my $pid   = $info->{pid};
    my $entry = $self->{tracked}{$pid};

    if ( $entry && $entry->{start_epoch} != $info->{start_epoch} ) {
        # PID reuse — reset.
        delete $self->{tracked}{$pid};
        $entry = undef;
    }

    if ( !$entry ) {
        $entry = $self->{tracked}{$pid} = {
            pid         => $pid,
            start_epoch => $info->{start_epoch},
            instance    => $info->{instance},
            peak_rss    => $info->{rss_kb},
            peak_swap   => $info->{swap_kb},
            alerted     => { runtime => 0, memory => 0 },
        };
    }

    $entry->{peak_rss}  = $info->{rss_kb}  if $info->{rss_kb}  > $entry->{peak_rss};
    $entry->{peak_swap} = $info->{swap_kb} if $info->{swap_kb} > $entry->{peak_swap};
    $entry->{instance}  = $info->{instance};
    $entry->{last_info} = $info;

    $self->_evaluate( $entry, $info );
    return;
}

sub _evaluate {
    my ( $self, $entry, $info ) = @_;

    my $cfg            = $self->{config};
    my $now            = $self->{now_cb}->();
    my $runtime        = $now - $entry->{start_epoch};
    my $rss_mb         = $info->{rss_kb} / 1024;

    my $ignored_script   = _is_ignored( $info->{script},   $cfg->{ignore_scripts} );
    my $ignored_instance = _is_ignored( $info->{instance}, $cfg->{ignore_instances} );
    return if $ignored_instance;

    if (  !$entry->{alerted}{runtime}
        && $runtime > $cfg->{runtime_threshold_seconds}
        && !$info->{idle}
        && !$ignored_script )
    {
        $entry->{alerted}{runtime} = 1;
        $self->_dispatch( 'runtime', $entry, $info, $runtime );
    }

    if (  !$entry->{alerted}{memory}
        && $rss_mb > $cfg->{memory_threshold_mb} )
    {
        $entry->{alerted}{memory} = 1;
        $self->_dispatch( 'memory', $entry, $info, $runtime );
    }

    return;
}

sub _is_ignored {
    my ( $value, $list ) = @_;
    return 0 unless defined $value && $list;
    for my $item (@$list) {
        return 1 if $item eq $value;
        # Allow basename-only matches for scripts.
        if ( $value =~ m{/\Q$item\E\z} ) {
            return 1;
        }
    }
    return 0;
}

sub _dispatch {
    my ( $self, $reason, $entry, $info, $runtime ) = @_;

    $self->log(
        sprintf(
            'alert reason=%s pid=%d instance=%s script=%s runtime=%ds rss_kb=%d swap_kb=%d',
            $reason,         $info->{pid},    $info->{instance},
            $info->{script} // '(idle)', $runtime, $info->{rss_kb}, $info->{swap_kb}
        )
    );

    my $cap = $self->{capture}->capture(
        pid      => $info->{pid},
        instance => $info->{instance},
    );

    my $tail = $cap->{tail} // '';

    my $alert = {
        reason          => $reason,
        instance        => $info->{instance},
        pid             => $info->{pid},
        script          => $info->{script},
        runtime_seconds => $runtime,
        rss_kb          => $info->{rss_kb},
        swap_kb         => $info->{swap_kb},
        host            => $self->{hostname},
        capture_tail    => $tail,
    };

    my $res = $self->{slack}->send_alert($alert);
    if ( !$res->{success} ) {
        $self->log(
            sprintf(
                'slack post failed pid=%d status=%s reason=%s',
                $info->{pid}, $res->{status} // '?', $res->{reason} // '?'
            )
        );
    }
    return;
}

sub run {
    my ($self) = @_;
    my $interval = $self->{config}{poll_interval_seconds};
    $self->log("koha-starman-worker-watcher started (poll=${interval}s)");
    local $SIG{TERM} = sub { $self->{_stop} = 1 };
    local $SIG{INT}  = sub { $self->{_stop} = 1 };
    until ( $self->{_stop} ) {
        eval { $self->scan(); 1 }
            or $self->log("scan error: $@");
        my $slept = 0;
        while ( $slept < $interval && !$self->{_stop} ) {
            sleep 1;
            $slept++;
        }
    }
    $self->log('koha-starman-worker-watcher stopped');
    return;
}

1;
