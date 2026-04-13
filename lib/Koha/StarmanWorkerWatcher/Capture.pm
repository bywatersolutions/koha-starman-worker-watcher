package Koha::StarmanWorkerWatcher::Capture;

use Modern::Perl;

use File::Path qw(make_path);
use File::Spec;
use POSIX      qw(strftime :sys_wait_h);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        enabled           => $args{enabled}           // 1,
        duration_seconds  => $args{duration_seconds}  // 5,
        output_dir        => $args{output_dir}        // '/var/lib/koha-starman-worker-watcher/captures',
        keep              => $args{keep}              // 50,
        attach_tail_lines => $args{attach_tail_lines} // 40,
        strace_binary     => $args{strace_binary}     // 'strace',
    }, $class;
}

sub capture {
    my ( $self, %args ) = @_;
    my $pid      = $args{pid}      or return { ok => 0, error => 'pid required' };
    my $instance = $args{instance} // 'unknown';

    return { ok => 0, skipped => 'disabled' } unless $self->{enabled};

    make_path( $self->{output_dir} ) unless -d $self->{output_dir};

    my $ts   = strftime( '%Y%m%dT%H%M%SZ', gmtime );
    my $name = "${instance}-${pid}-${ts}.strace.gz";
    my $path = File::Spec->catfile( $self->{output_dir}, $name );

    # strace -o '|cmd' pipes its output through a shell command. We use this
    # to stream-compress with gzip -c into the destination file, so there is
    # never an uncompressed intermediate on disk.
    my $shell_target = sprintf( q{|gzip -c > %s}, _shell_quote($path) );

    my $child = fork();
    if ( !defined $child ) {
        return { ok => 0, error => "fork failed: $!" };
    }

    if ( $child == 0 ) {
        # Child: exec strace.
        exec(
            $self->{strace_binary},
            '-p', $pid,
            '-tt',
            '-s', '256',
            '-o', $shell_target,
        );
        exit(127);
    }

    my $deadline = time() + $self->{duration_seconds};
    while ( time() < $deadline ) {
        my $reaped = waitpid( $child, WNOHANG );
        last if $reaped > 0;
        select( undef, undef, undef, 0.2 );
    }

    if ( waitpid( $child, WNOHANG ) == 0 ) {
        kill 'TERM', $child;
        my $grace = time() + 2;
        while ( time() < $grace ) {
            last if waitpid( $child, WNOHANG ) > 0;
            select( undef, undef, undef, 0.1 );
        }
        kill 'KILL', $child if waitpid( $child, WNOHANG ) == 0;
        waitpid( $child, 0 );
    }

    my $tail = $self->_read_tail($path);
    $self->_rotate();

    return {
        ok   => 1,
        path => $path,
        tail => $tail,
    };
}

sub _read_tail {
    my ( $self, $gz_path ) = @_;
    return '' unless -f $gz_path;

    my $buffer = '';
    if ( !gunzip( $gz_path => \$buffer ) ) {
        return '';
    }

    my @lines = split /\n/, $buffer;
    my $n     = $self->{attach_tail_lines};
    if ( @lines > $n ) {
        @lines = @lines[ -$n .. -1 ];
    }
    return join( "\n", @lines );
}

sub _rotate {
    my ($self) = @_;
    my $keep = $self->{keep};
    return if $keep <= 0;

    opendir( my $dh, $self->{output_dir} ) or return;
    my @files = grep { /\.strace\.gz\z/ } readdir($dh);
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

sub _shell_quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

1;
