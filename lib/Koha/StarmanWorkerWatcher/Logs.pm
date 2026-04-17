package Koha::StarmanWorkerWatcher::Logs;

use Modern::Perl;

use Path::Tiny  qw(path);
use POSIX       qw(strftime);
use Time::Local qw(timegm);

# Koha's Debian packaging writes per-instance Apache and Plack logs under
# /var/log/koha/<instance>/. access logs get the time-window + 4xx/5xx
# treatment (that is where the 502 from a killed upstream shows up with
# the culprit URL); error logs get time-window only; plack-error.log
# falls back to raw tail because its format is inconsistent and often has
# no parseable timestamp.
my @FILES = (
    # Apache combined access logs — the 502 from a killed upstream
    # lands here with the culprit URL. Filter by 4xx/5xx within ±60s
    # of the kill time (access log lines don't carry the worker PID,
    # so PID matching isn't an option here).
    { name => 'opac-access.log',     filter => 'http_error' },
    { name => 'intranet-access.log', filter => 'http_error' },
    { name => 'plack.log',           filter => 'http_error' },

    # Koha log4perl output. Koha's log4perl layout has the writer's
    # PID in the second bracket (`[%P]` → `[12345]`), so we grep each
    # file for `[<killed_pid>]` to surface only lines the killed
    # worker wrote. `opac-error.log` and `intranet-error.log` also
    # receive Apache's own error output, but Apache uses
    # `[pid <apache_child_pid>]` (different PID, different syntax),
    # so it is naturally excluded by the strict bracket match.
    { name => 'opac-error.log',           filter => 'pid_match' },
    { name => 'intranet-error.log',       filter => 'pid_match' },
    { name => 'api-error.log',            filter => 'pid_match' },
    { name => 'plack-intranet-error.log', filter => 'pid_match' },
    { name => 'plack-opac-error.log',     filter => 'pid_match' },
    { name => 'plack-api-error.log',      filter => 'pid_match' },

    # Starman master lifecycle log; inconsistent format and the PID
    # in the body is the master's, not the worker's. Raw tail only.
    { name => 'plack-error.log',          filter => 'tail' },
);

my $WINDOW_SECONDS = 60;
my $TAIL_LINES     = 1000;
my $KEEP           = 50;

my %MONTH = (
    Jan => 0, Feb => 1, Mar => 2, Apr => 3,
    May => 4, Jun => 5, Jul => 6, Aug => 7,
    Sep => 8, Oct => 9, Nov => 10, Dec => 11,
);

# Env overrides exist only so t/ can redirect to a tempdir; production
# never sets them, matching the pattern used by Proc.pm's KSWW_PROC_ROOT.
sub _base_dir   { $ENV{KSWW_LOG_ROOT}    // '/var/log/koha' }
sub _output_dir { $ENV{KSWW_CAPTURE_DIR} // '/var/lib/koha-starman-worker-watcher/captures' }

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

sub collect {
    my ( $self, %args ) = @_;
    my $pid       = $args{pid}       or return { ok => 0, error => 'pid required' };
    my $instance  = $args{instance}  // 'unknown';
    my $signal    = $args{signal}    // '';
    my $kill_time = $args{kill_time} // time();

    # The instance name is parsed from KOHA_CONF, but path traversal via
    # a maliciously-crafted env would be bad; reject anything that isn't
    # a plausible site name.
    return { ok => 0, error => "invalid instance name: $instance" }
        unless $instance =~ /\A[A-Za-z0-9_.-]+\z/;

    my $dir = path( _base_dir(), $instance );

    my @results;
    my @access_matches;
    for my $spec (@FILES) {
        my $file   = $dir->child( $spec->{name} );
        my $filter = $spec->{filter};
        my @lines  = _match_lines( $file, $filter, $kill_time, $pid );
        push @results, {
            name   => $spec->{name},
            path   => "$file",
            lines  => \@lines,
            exists => ( $file->is_file ? 1 : 0 ),
            filter => $filter,
        };
        if ( $filter eq 'http_error' && @lines ) {
            push @access_matches, map { "[$spec->{name}] $_" } @lines;
        }
    }

    my $saved_path = _write_bundle( $instance, $pid, $signal, $kill_time, \@results );
    _rotate();

    return {
        ok             => 1,
        path           => $saved_path,
        files          => \@results,
        access_matches => \@access_matches,
        kill_time      => $kill_time,
    };
}

sub _match_lines {
    my ( $file, $filter, $kill_time, $pid ) = @_;
    return () unless $file->is_file;

    my @lines = eval { $file->lines_utf8( { chomp => 1 } ) };
    return () if $@;

    if ( $filter eq 'tail' ) {
        return @lines > $TAIL_LINES ? @lines[ -$TAIL_LINES .. -1 ] : @lines;
    }

    if ( $filter eq 'pid_match' ) {

        # log4perl layout `[%d] [%P] [%p] %m` puts the writer's PID in a
        # bracket by itself, so a literal `[<pid>]` match pinpoints lines
        # written by our killed worker. Apache's own `[pid N:tid N]` in
        # mixed files has `:tid` inside, so it does not match.
        my $needle = "[$pid]";
        my @keep = grep { index( $_, $needle ) >= 0 } @lines;
        return @keep > $TAIL_LINES ? @keep[ -$TAIL_LINES .. -1 ] : @keep;
    }

    # http_error: access-log time window + 4xx/5xx. Walk lines, parse
    # timestamps, and apply the status regex. Access logs always carry a
    # timestamp per line so the carry-forward trick isn't needed here.
    my @keep;
    for my $line (@lines) {
        my $ts = _access_log_epoch($line);
        next unless defined $ts;
        next if abs( $ts - $kill_time ) > $WINDOW_SECONDS;

        # Apache/Plack combined log format: ... "METHOD URL HTTP/x" STATUS SIZE ...
        next unless $line =~ /"\s+[45]\d\d\s/;
        push @keep, $line;
    }

    if ( @keep > $TAIL_LINES ) {
        @keep = @keep[ -$TAIL_LINES .. -1 ];
    }
    return @keep;
}

sub _access_log_epoch {
    my ($line) = @_;

    # Apache / Plack combined access format: [16/Apr/2026:10:42:17 +0000]
    return undef
        unless $line
        =~ m{\[(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})\]};

    my ( $day, $mon, $year, $h, $m, $s, $sign, $tzh, $tzm ) =
        ( $1, $2, $3, $4, $5, $6, $7, $8, $9 );
    return undef unless exists $MONTH{$mon};
    my $epoch  = timegm( $s, $m, $h, $day, $MONTH{$mon}, $year );
    my $offset = ( $tzh * 3600 + $tzm * 60 ) * ( $sign eq '-' ? 1 : -1 );
    return $epoch + $offset;
}

sub _write_bundle {
    my ( $instance, $pid, $signal, $kill_time, $results ) = @_;

    my $out = path( _output_dir() );
    $out->mkpath unless $out->is_dir;

    my $ts   = strftime( '%Y%m%dT%H%M%SZ', gmtime($kill_time) );
    my $sig  = length $signal ? "-$signal" : '';
    my $file = $out->child("${instance}-${pid}-${ts}${sig}.logs.txt");

    my $kill_iso = strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime($kill_time) );
    my $body     = sprintf(
        "# kill_time=%s (±%ds) instance=%s pid=%d signal=%s\n\n",
        $kill_iso, $WINDOW_SECONDS, $instance, $pid, $signal,
    );
    for my $r (@$results) {
        my $header = sprintf( "=== %s (%s) ===\n", $r->{path}, $r->{filter} );
        if ( !$r->{exists} ) {
            $body .= $header . "(file not found)\n\n";
            next;
        }
        if ( !@{ $r->{lines} } ) {
            my $note =
                  $r->{filter} eq 'http_error' ? "(no 4xx/5xx entries in window)\n\n"
                : $r->{filter} eq 'pid_match'  ? "(no lines matching [$pid])\n\n"
                :                                "(empty tail)\n\n";
            $body .= $header . $note;
            next;
        }
        $body .= $header . join( "\n", @{ $r->{lines} } ) . "\n\n";
    }
    $file->spew_utf8($body);
    return "$file";
}

sub _rotate {
    my $dir = path( _output_dir() );
    return unless $dir->is_dir;

    my @entries =
        sort { $b->[1] <=> $a->[1] }
        map  { [ $_, ( $_->stat )[9] // 0 ] }
        $dir->children(qr/\.logs\.txt\z/);

    return if @entries <= $KEEP;
    for my $stale ( @entries[ $KEEP .. $#entries ] ) {
        $stale->[0]->remove;
    }
    return;
}

1;
