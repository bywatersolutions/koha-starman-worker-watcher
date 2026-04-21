package Koha::StarmanWorkerWatcher::Capture;

use Modern::Perl;

use File::Path             qw(make_path);
use File::Spec;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use POSIX                  qw(strftime :sys_wait_h);

# Forensic capture on alert. Always reads /proc/PID/{wchan,syscall,stack}
# and optionally runs:
#
#   - gdb -batch -p PID -ex bt -ex detach   (fast C backtrace, ~ms,
#                                            does not risk an Apache 502)
#   - strace -p PID for duration_seconds    (continuous syscall trace,
#                                            gzipped to a sidecar file;
#                                            pauses the worker for the
#                                            whole window so can trip
#                                            Apache's ProxyTimeout)
#   - SIGUSR2 to the worker                 (cooperating handler dumps
#                                            Carp::longmess; see Stack.pm)
#
# Every on-by-default probe produces a section in the main .stack.txt
# capture; strace additionally leaves a .strace.gz sidecar next to it.
# The last tail_lines lines of the combined body are included inline in
# the Slack alert.

sub new {
    my ( $class, %args ) = @_;
    return bless {
        enabled                 => $args{enabled}                 // 1,
        output_dir              => $args{output_dir}              // '/var/lib/koha-starman-worker-watcher/captures',
        keep                    => $args{keep}                    // 50,
        tail_lines              => $args{tail_lines}              // $args{attach_tail_lines} // 40,
        gdb_enabled             => $args{gdb_enabled}             // 0,
        gdb_binary              => $args{gdb_binary}              // 'gdb',
        gdb_timeout             => $args{gdb_timeout}             // 10,
        strace_enabled          => $args{strace_enabled}          // 0,
        strace_binary           => $args{strace_binary}           // 'strace',
        strace_duration_seconds => $args{strace_duration_seconds} // 5,
        perl_stack_signal       => $args{perl_stack_signal}       // 0,
        perl_stack_wait         => $args{perl_stack_wait}         // 2,
    }, $class;
}

sub capture {
    my ( $self, %args ) = @_;
    my $pid      = $args{pid}      or return { ok => 0, error => 'pid required' };
    my $instance = $args{instance} // 'unknown';

    return { ok => 0, skipped => 'disabled' } unless $self->{enabled};

    make_path( $self->{output_dir} ) unless -d $self->{output_dir};

    my $ts   = strftime( '%Y%m%dT%H%M%SZ', gmtime );
    my $base = "${instance}-${pid}-${ts}";
    my $path = File::Spec->catfile( $self->{output_dir}, "$base.stack.txt" );

    my @sections = (
        _proc_section( $pid, 'wchan' ),
        _proc_section( $pid, 'syscall' ),
        _proc_section( $pid, 'stack' ),
        $self->_perl_stack($pid),
    );

    if ( $self->{gdb_enabled} ) {
        push @sections, $self->_gdb_backtrace($pid);
    }

    if ( $self->{strace_enabled} ) {
        my $strace_path = File::Spec->catfile( $self->{output_dir}, "$base.strace.gz" );
        push @sections, $self->_strace_trace( $pid, $strace_path );
    }

    my $body = join( "\n\n", @sections ) . "\n";

    if ( !open( my $fh, '>', $path ) ) {
        return { ok => 0, error => "write failed: $!" };
    }
    else {
        print {$fh} $body;
        close $fh;
    }

    $self->_rotate;

    # Tail: keep the gdb backtrace readable in Slack by taking the last
    # N lines of the combined body.
    my @lines = split /\n/, $body;
    if ( @lines > $self->{tail_lines} ) {
        @lines = @lines[ -$self->{tail_lines} .. -1 ];
    }

    return {
        ok   => 1,
        path => $path,
        tail => join( "\n", @lines ),
    };
}

sub _perl_stack {
    my ( $self, $pid ) = @_;

    my $header = "=== Perl stack (pid $pid, via SIGUSR2) ===\n";

    # SIGUSR2's default OS disposition is "terminate the process". On a
    # worker that has not loaded Koha::StarmanWorkerWatcher::Stack in
    # its plack.psgi, sending USR2 would KILL the worker we're trying
    # to inspect. Opt-in via capture.perl_stack_signal, so new installs
    # stay safe until the plack.psgi edit is in place.
    if ( !$self->{perl_stack_signal} ) {
        return $header . "(disabled: set capture.perl_stack_signal: true"
            . " once plack.psgi loads Koha::StarmanWorkerWatcher::Stack)";
    }

    my $path = $self->{output_dir} . "/koha-stack-$pid.txt";

    # Clear any stale dump so we only read the fresh one.
    unlink $path;

    if ( !kill( 'USR2', $pid ) ) {
        return $header . "(kill USR2 failed: $!)";
    }

    # Perl safe-signals only dispatch between ops; if the worker is stuck
    # in a long C-level call (e.g. a slow DBI query) the handler won't
    # fire until control returns to the interpreter. We poll briefly and
    # give up rather than block the watcher loop.
    my $waited = 0;
    my $step   = 0.1;
    my $max    = $self->{perl_stack_wait};
    while ( !-e $path && $waited < $max ) {
        select undef, undef, undef, $step;
        $waited += $step;
    }

    if ( !-e $path ) {
        return $header
            . "(no dump within ${max}s -- handler not installed, or worker stuck in C)";
    }

    my $content;
    if ( open my $fh, '<', $path ) {
        local $/;
        $content = <$fh>;
        close $fh;
    }
    unlink $path;

    return $header . ( defined $content && length $content ? $content : '(empty)' );
}

sub _proc_section {
    my ( $pid, $name ) = @_;
    my $proc_path = "/proc/$pid/$name";
    my $content;
    if ( open my $fh, '<', $proc_path ) {
        local $/;
        $content = <$fh>;
        close $fh;
        chomp $content if defined $content;
    }
    else {
        $content = "(read failed: $!)";
    }
    return "=== $proc_path ===\n" . ( defined $content && length $content ? $content : '(empty)' );
}

sub _gdb_backtrace {
    my ( $self, $pid ) = @_;

    # If the worker is blocked inside a DB call, the SQL is sitting in a
    # stack frame of libmariadb/libmysqlclient. `frame function` jumps to
    # that frame if present; when it's not, gdb prints an error and -batch
    # moves on to the next -ex, so these are safe no-ops on other stacks.
    # Requires debuginfo for the client lib for arg names to resolve.
    # Debian's stock perl ships no debuginfo, so reading PL_curcop from
    # gdb is not feasible; Perl-level backtraces come from the in-process
    # SIGUSR2 handler instead (see _perl_stack).
    my @cmd = (
        $self->{gdb_binary},
        '-batch', '-nx',
        '-p', $pid,
        '-ex', 'set pagination off',
        '-ex', 'bt',
        '-ex', 'frame function mysql_real_query',
        '-ex', 'printf "QUERY: %s\n", stmt_str',
        '-ex', 'frame function mysql_send_query',
        '-ex', 'printf "QUERY: %s\n", stmt_str',
        '-ex', 'frame function mysql_stmt_prepare',
        '-ex', 'printf "PREPARE: %s\n", stmt_str',
        '-ex', 'detach',
        '-ex', 'quit',
    );

    my $out;
    my $err;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "gdb timeout after $self->{gdb_timeout}s\n" };
        alarm( $self->{gdb_timeout} );
        open( my $fh, '-|', @cmd ) or die "fork gdb failed: $!\n";
        local $/;
        $out = <$fh>;
        close $fh;
        alarm 0;
        1;
    };
    if ( !$ok ) {
        $err = $@;
        alarm 0;
    }

    my $header = "=== gdb backtrace (pid $pid) ===\n";
    return $header . "(failed: $err)" if defined $err;
    return $header . ( defined $out && length $out ? $out : '(empty)' );
}

sub _strace_trace {
    my ( $self, $pid, $gz_path ) = @_;

    my $header = "=== strace (pid $pid) ===\n";

    # `strace -o '|cmd'` pipes output through a shell command. Using
    # `gzip -c > file` keeps the full trace compressed on disk without
    # ever materialising an uncompressed intermediate -- useful because
    # these traces can be many MiB and we rotate them as sidecars.
    my $shell_target = sprintf( q{|gzip -c > %s}, _shell_quote($gz_path) );

    my $child = fork();
    if ( !defined $child ) {
        return $header . "(fork failed: $!)";
    }

    if ( $child == 0 ) {
        exec(
            $self->{strace_binary},
            '-p', $pid,
            '-tt',
            '-s', '256',
            '-o', $shell_target,
        );
        exit(127);
    }

    my $deadline = time() + $self->{strace_duration_seconds};
    while ( time() < $deadline ) {
        last if waitpid( $child, WNOHANG ) > 0;
        select undef, undef, undef, 0.2;
    }

    # Bring strace down cleanly if it's still running; SIGTERM makes it
    # flush its output file and detach from the traced process.
    if ( waitpid( $child, WNOHANG ) == 0 ) {
        kill 'TERM', $child;
        my $grace = time() + 2;
        while ( time() < $grace ) {
            last if waitpid( $child, WNOHANG ) > 0;
            select undef, undef, undef, 0.1;
        }
        kill 'KILL', $child if waitpid( $child, WNOHANG ) == 0;
        waitpid( $child, 0 );
    }

    my $tail = _read_gz_tail( $gz_path, $self->{tail_lines} );
    return $header . "(sidecar: $gz_path)\n"
        . ( length $tail ? $tail : '(empty)' );
}

sub _read_gz_tail {
    my ( $path, $n ) = @_;
    return '' unless -f $path;

    my $buffer = '';
    return '' unless gunzip( $path => \$buffer );

    my @lines = split /\n/, $buffer;
    if ( @lines > $n ) {
        @lines = @lines[ -$n .. -1 ];
    }
    return join( "\n", @lines );
}

sub _shell_quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub _rotate {
    my ($self) = @_;
    my $keep = $self->{keep};
    return if $keep <= 0;

    # Rotate each artifact kind separately so enabling/disabling strace
    # doesn't skew the retention window for stack captures.
    for my $pattern ( qr/\.stack\.txt\z/, qr/\.strace\.gz\z/ ) {
        opendir( my $dh, $self->{output_dir} ) or next;
        my @files = grep { $_ =~ $pattern } readdir($dh);
        closedir($dh);

        my @entries = map {
            my $p = File::Spec->catfile( $self->{output_dir}, $_ );
            [ $p, ( stat($p) )[9] // 0 ];
        } @files;

        @entries = sort { $b->[1] <=> $a->[1] } @entries;
        next if @entries <= $keep;

        for my $stale ( @entries[ $keep .. $#entries ] ) {
            unlink $stale->[0];
        }
    }
    return;
}

1;
