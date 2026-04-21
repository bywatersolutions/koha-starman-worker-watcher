package Koha::StarmanWorkerWatcher::Slack;

use Modern::Perl;

use HTTP::Tiny;
use JSON::PP qw(encode_json);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        enabled     => exists $args{enabled} ? $args{enabled} : 1,
        webhook_url => $args{webhook_url},
        username    => $args{username}   // 'koha-worker-watcher',
        icon_emoji  => $args{icon_emoji} // ':rotating_light:',
        dry_run     => $args{dry_run}    // 0,
        http        => $args{http}       // HTTP::Tiny->new( timeout => 10 ),
    }, $class;
}

sub format_alert {
    my ( $self, $alert ) = @_;

    my $rss_mib  = sprintf( '%.1f', ( $alert->{rss_kb}  // 0 ) / 1024 );
    my $swap_mib = sprintf( '%.1f', ( $alert->{swap_kb} // 0 ) / 1024 );
    my $runtime  = _fmt_duration( $alert->{runtime_seconds} // 0 );
    my $script   = $alert->{script} // '';
    $script = '(none)' if $script eq '';

    my @lines = (
        ":rotating_light: Koha worker exceeded $alert->{reason}",
        "Instance: $alert->{instance}",
        "PID: $alert->{pid}",
        "Script: $script",
        "Runtime: $runtime",
        "RSS: ${rss_mib} MiB",
        "Swap: ${swap_mib} MiB",
        "Host: $alert->{host}",
    );

    my $text = join( "\n", @lines );

    if ( defined $alert->{capture_tail} && length $alert->{capture_tail} ) {
        my $tail = $alert->{capture_tail};

        # Slack soft-limits text length; cap the tail to stay under it.
        my $max = 2800;
        if ( length($tail) > $max ) {
            $tail = substr( $tail, -$max );
            $tail = "...(truncated)...\n" . $tail;
        }
        $text .= "\n```\n" . $tail . "\n```";
    }

    return $text;
}

sub send_alert {
    my ( $self, $alert ) = @_;
    return $self->_post( $self->format_alert($alert) );
}

sub send_notice {
    my ( $self, $text ) = @_;
    return $self->_post($text);
}

sub _post {
    my ( $self, $text ) = @_;

    my $payload = {
        text       => $text,
        username   => $self->{username},
        icon_emoji => $self->{icon_emoji},
    };

    if ( !$self->{enabled} ) {
        print STDOUT "[log-only slack] $text\n";
        return { success => 1, log_only => 1 };
    }

    if ( $self->{dry_run} || !$self->{webhook_url} ) {
        print STDOUT "[dry-run slack] $text\n";
        return { success => 1, dry_run => 1 };
    }

    my $res = $self->{http}->post(
        $self->{webhook_url},
        {
            headers => { 'Content-Type' => 'application/json' },
            content => encode_json($payload),
        }
    );

    return {
        success => $res->{success},
        status  => $res->{status},
        reason  => $res->{reason},
    };
}

sub _fmt_duration {
    my ($seconds) = @_;
    $seconds = int($seconds);
    my $h = int( $seconds / 3600 );
    my $m = int( ( $seconds % 3600 ) / 60 );
    my $s = $seconds % 60;
    return sprintf( '%02d:%02d:%02d', $h, $m, $s );
}

1;
