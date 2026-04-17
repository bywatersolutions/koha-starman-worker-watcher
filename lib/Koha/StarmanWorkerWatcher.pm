package Koha::StarmanWorkerWatcher;

use Modern::Perl;

use Sys::Hostname qw(hostname);
use YAML::XS      ();

use Koha::StarmanWorkerWatcher::Proc;
use Koha::StarmanWorkerWatcher::Slack;
use Koha::StarmanWorkerWatcher::Capture;
use Koha::StarmanWorkerWatcher::Logs;

our $VERSION = '0.4.0';

# Once the worker has exited, wait this long before grepping so Apache
# has time to notice the dropped upstream and flush the 502 access-log
# entry.
my $POST_KILL_DELAY_SECONDS = 1;

sub new {
    my ( $class, %args ) = @_;

    my $config = $args{config}
        or die "config required\n";

    my $self = bless {
        config    => $config,
        hostname  => $args{hostname}  // hostname(),
        slack     => $args{slack}     // Koha::StarmanWorkerWatcher::Slack->new(
            enabled     => exists $config->{slack}{enabled} ? $config->{slack}{enabled} : 1,
            webhook_url => $config->{slack}{webhook_url} // '',
            username    => $config->{slack}{username}    // 'koha-worker-watcher',
            icon_emoji  => $config->{slack}{icon_emoji}  // ':rotating_light:',
            dry_run     => $args{dry_run} // 0,
        ),
        capture   => $args{capture}   // Koha::StarmanWorkerWatcher::Capture->new(
            %{ $config->{capture} // {} }
        ),
        logs      => $args{logs}      // Koha::StarmanWorkerWatcher::Logs->new(),
        clock_ticks => Koha::StarmanWorkerWatcher::Proc::clock_ticks(),
        btime       => Koha::StarmanWorkerWatcher::Proc::btime(),
        tracked     => {},
        now_cb      => $args{now_cb} // sub { time() },
        log_cb      => $args{log_cb} // sub { print STDERR "@_\n" },
        kill_cb     => $args{kill_cb} // sub { my ( $sig, $pid ) = @_; return kill( $sig, $pid ); },
        sleep_cb    => $args{sleep_cb} // sub { my ($s) = @_; sleep $s if $s > 0; },
        alive_cb    => $args{alive_cb} // sub { my ($pid) = @_; return kill( 0, $pid ) ? 1 : 0; },
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

    # Auto-kill thresholds. Both must be set (defined and > 0) for kill
    # logic to be active. ANDed at evaluation time, just like the alert
    # thresholds. Default undef = disabled.
    $parsed->{kill_runtime_threshold_seconds} //= undef;
    $parsed->{kill_memory_threshold_mb}       //= undef;

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
            pid              => $pid,
            start_epoch      => $info->{start_epoch},
            instance         => $info->{instance},
            peak_rss         => $info->{rss_kb},
            peak_swap        => $info->{swap_kb},
            alerted          => 0,
            sigterm_sent     => 0,
            sigkill_sent     => 0,
        };
    }

    $entry->{peak_rss}  = $info->{rss_kb}  if $info->{rss_kb}  > $entry->{peak_rss};
    $entry->{peak_swap} = $info->{swap_kb} if $info->{swap_kb} > $entry->{peak_swap};
    $entry->{instance}  = $info->{instance};
    $entry->{last_info} = $info;

    $self->_evaluate( $entry, $info );
    $self->_evaluate_kill( $entry, $info );
    return;
}

sub _evaluate {
    my ( $self, $entry, $info ) = @_;

    return if $entry->{alerted};

    my $cfg     = $self->{config};
    my $now     = $self->{now_cb}->();
    my $runtime = $now - $entry->{start_epoch};
    my $rss_mb  = $info->{rss_kb} / 1024;

    my $ignored_instance = _is_ignored( $info->{instance}, $cfg->{ignore_instances} );
    return if $ignored_instance;

    my $ignored_script = _is_ignored( $info->{script}, $cfg->{ignore_scripts} );
    return if $ignored_script;
    return if $info->{idle};

    # AND logic: both thresholds must be exceeded at the same sample.
    my $runtime_over = $runtime > $cfg->{runtime_threshold_seconds};
    my $memory_over  = $rss_mb  > $cfg->{memory_threshold_mb};
    return unless $runtime_over && $memory_over;

    $entry->{alerted} = 1;
    $self->_dispatch( 'runtime and memory thresholds', $entry, $info, $runtime );
    return;
}

sub _evaluate_kill {
    my ( $self, $entry, $info ) = @_;

    my $cfg          = $self->{config};
    my $kill_runtime = $cfg->{kill_runtime_threshold_seconds};
    my $kill_memory  = $cfg->{kill_memory_threshold_mb};

    # Kill is disabled unless at least one threshold is set. When only
    # one is set, the unset one is ignored (treated as a wildcard).
    return unless defined $kill_runtime || defined $kill_memory;

    return if _is_ignored( $info->{instance}, $cfg->{ignore_instances} );
    return if _is_ignored( $info->{script},   $cfg->{ignore_scripts} );
    return if $info->{idle};

    my $now     = $self->{now_cb}->();
    my $runtime = $now - $entry->{start_epoch};
    my $rss_mb  = $info->{rss_kb} / 1024;

    my $runtime_over = !defined $kill_runtime || $runtime > $kill_runtime;
    my $memory_over  = !defined $kill_memory  || $rss_mb  > $kill_memory;
    return unless $runtime_over && $memory_over;

    if ( !$entry->{sigterm_sent} ) {
        $entry->{sigterm_sent} = 1;
        $self->_kill_worker( 'TERM', $entry, $info, $runtime );
        return;
    }

    if ( !$entry->{sigkill_sent} ) {
        $entry->{sigkill_sent} = 1;
        $self->_kill_worker( 'KILL', $entry, $info, $runtime );
    }
    return;
}

sub _kill_worker {
    my ( $self, $signal, $entry, $info, $runtime ) = @_;

    my $kill_time = $self->{now_cb}->();
    my $sent      = $self->{kill_cb}->( $signal, $info->{pid} ) || 0;

    $self->log(
        sprintf(
            'kill signal=%s pid=%d instance=%s script=%s runtime=%ds rss_kb=%d sent=%d',
            $signal,                     $info->{pid}, $info->{instance},
            $info->{script} // '(idle)', $runtime,     $info->{rss_kb}, $sent
        )
    );

    # Wait for the worker to actually exit before grepping — Apache
    # does not log the 502 until the upstream connection drops, and
    # the drop only happens when the worker exits. Poll once a second
    # until confirmed.
    my $waited = 0;
    while ( $self->{alive_cb}->( $info->{pid} ) ) {
        $self->{sleep_cb}->(1);
        $waited++;
    }
    $self->log(
        sprintf(
            'kill confirmed pid=%d signal=%s waited=%ds',
            $info->{pid}, $signal, $waited
        )
    );

    # Give Apache a moment to flush the 502 upstream-gone entry.
    $self->{sleep_cb}->($POST_KILL_DELAY_SECONDS);

    my $rss_mib = sprintf( '%.1f', $info->{rss_kb} / 1024 );
    my $notice  = sprintf(
        ':skull: koha-starman-worker-watcher sent SIG%s to runaway worker'
            . ' on %s (instance=%s pid=%d script=%s runtime=%ds rss=%s MiB)',
        $signal, $self->{hostname}, $info->{instance}, $info->{pid},
        $info->{script} // '(idle)', $runtime, $rss_mib,
    );

    my $log_result = $self->{logs}->collect(
        pid       => $info->{pid},
        instance  => $info->{instance},
        signal    => $signal,
        kill_time => $kill_time,
    );
    if ( $log_result->{ok} ) {
        my $matches = $log_result->{access_matches} // [];
        $self->log(
            sprintf(
                'logs collected pid=%d signal=%s bundle=%s access_matches=%d',
                $info->{pid}, $signal,
                $log_result->{path} // '', scalar @$matches
            )
        );
        if (@$matches) {
            my $snippet = join( "\n", @$matches );
            my $max     = 1500;
            if ( length $snippet > $max ) {
                $snippet = substr( $snippet, -$max );
                $snippet = "...(truncated)...\n$snippet";
            }
            $notice .= "\nRecent 4xx/5xx around kill time:\n```\n$snippet\n```";
        }
        if ( $log_result->{path} ) {
            $notice .= "\nFull log bundle: $log_result->{path}";
        }
    }
    elsif ( !$log_result->{skipped} ) {
        $self->log(
            sprintf(
                'log collection failed pid=%d signal=%s error=%s',
                $info->{pid}, $signal, $log_result->{error} // '?'
            )
        );
    }

    my $res = $self->{slack}->send_notice($notice);
    if ( !$res->{success} ) {
        $self->log(
            sprintf(
                'slack kill notice failed pid=%d signal=%s status=%s reason=%s',
                $info->{pid}, $signal, $res->{status} // '?', $res->{reason} // '?'
            )
        );
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
    my $cfg      = $self->{config};
    my $interval = $cfg->{poll_interval_seconds};
    $self->log("koha-starman-worker-watcher started (poll=${interval}s)");

    # Startup notice to Slack. Only sent when a webhook URL is actually
    # configured; the Slack client still honors enabled/dry_run flags,
    # so log-only and dry-run runs get a [log-only slack] / [dry-run
    # slack] line on stdout instead of a real POST.
    if ( ( $cfg->{slack}{webhook_url} // '' ) ne '' ) {
        my $notice = sprintf(
            ':information_source: koha-starman-worker-watcher started on %s'
                . ' (poll=%ds, thresholds: runtime>%ds AND memory>%dMiB)',
            $self->{hostname}, $interval,
            $cfg->{runtime_threshold_seconds},
            $cfg->{memory_threshold_mb},
        );
        my $kr = $cfg->{kill_runtime_threshold_seconds};
        my $km = $cfg->{kill_memory_threshold_mb};
        if ( defined $kr || defined $km ) {
            my $rt = defined $kr ? "runtime>${kr}s" : 'runtime: any';
            my $mt = defined $km ? "memory>${km}MiB" : 'memory: any';
            $notice .= sprintf( ' (auto-kill: %s AND %s)', $rt, $mt );
        }
        my $res = $self->{slack}->send_notice($notice);
        if ( !$res->{success} ) {
            $self->log(
                sprintf(
                    'slack startup notice failed status=%s reason=%s',
                    $res->{status} // '?', $res->{reason} // '?'
                )
            );
        }
    }

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
