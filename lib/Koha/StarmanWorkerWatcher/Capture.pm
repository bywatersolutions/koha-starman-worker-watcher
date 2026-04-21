package Koha::StarmanWorkerWatcher::Capture;

use Modern::Perl;

use File::Path qw(make_path);
use File::Spec;
use POSIX      qw(strftime);

# One-shot forensic capture: reads a handful of /proc files and fires
# `gdb -batch -p PID -ex bt -ex detach` at the worker. gdb attaches via
# ptrace, walks the C stack (with Perl-level frames if libperl has debug
# symbols), then detaches — the traced process is paused for tens of
# milliseconds, not for seconds as with continuous strace. That stays
# well under Apache's ProxyTimeout, so attaching to a healthy-but-busy
# worker does not cause a 502 in the browser.

sub new {
    my ( $class, %args ) = @_;
    return bless {
        enabled     => $args{enabled}     // 1,
        output_dir  => $args{output_dir}  // '/var/lib/koha-starman-worker-watcher/captures',
        keep        => $args{keep}        // 50,
        tail_lines  => $args{tail_lines}  // $args{attach_tail_lines} // 40,
        gdb_binary  => $args{gdb_binary}  // 'gdb',
        gdb_timeout => $args{gdb_timeout} // 10,
    }, $class;
}

sub capture {
    my ( $self, %args ) = @_;
    my $pid      = $args{pid}      or return { ok => 0, error => 'pid required' };
    my $instance = $args{instance} // 'unknown';

    return { ok => 0, skipped => 'disabled' } unless $self->{enabled};

    make_path( $self->{output_dir} ) unless -d $self->{output_dir};

    my $ts   = strftime( '%Y%m%dT%H%M%SZ', gmtime );
    my $name = "${instance}-${pid}-${ts}.stack.txt";
    my $path = File::Spec->catfile( $self->{output_dir}, $name );

    my @sections = (
        _proc_section( $pid, 'wchan' ),
        _proc_section( $pid, 'syscall' ),
        _proc_section( $pid, 'stack' ),
        $self->_gdb_backtrace($pid),
    );

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

    my @cmd = (
        $self->{gdb_binary},
        '-batch', '-nx',
        '-p', $pid,
        '-ex', 'set pagination off',
        '-ex', 'bt',
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

sub _rotate {
    my ($self) = @_;
    my $keep = $self->{keep};
    return if $keep <= 0;

    opendir( my $dh, $self->{output_dir} ) or return;
    my @files = grep { /\.stack\.txt\z/ } readdir($dh);
    closedir($dh);

    my @entries = map {
        my $p = File::Spec->catfile( $self->{output_dir}, $_ );
        [ $p, ( stat($p) )[9] // 0 ];
    } @files;

    @entries = sort { $b->[1] <=> $a->[1] } @entries;
    return if @entries <= $keep;

    for my $stale ( @entries[ $keep .. $#entries ] ) {
        unlink $stale->[0];
    }
    return;
}

1;
