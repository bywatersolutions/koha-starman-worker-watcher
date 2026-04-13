package FakeProc;

use Modern::Perl;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Spec;

sub new {
    my ($class) = @_;
    my $root = tempdir( CLEANUP => 1 );
    my $self = bless { root => $root }, $class;
    $self->write_file( 'stat', "cpu 0 0 0 0 0 0 0 0 0 0\nbtime 1700000000\n" );
    return $self;
}

sub root { $_[0]->{root} }

sub write_file {
    my ( $self, $rel, $content ) = @_;
    my $path = File::Spec->catfile( $self->{root}, $rel );
    my ( undef, $dir ) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open( my $fh, '>', $path ) or die "fake proc write $path: $!";
    print $fh $content;
    close($fh);
    return;
}

sub add_process {
    my ( $self, %args ) = @_;
    my $pid     = $args{pid}     or die 'pid required';
    my $ppid    = $args{ppid}    // 1;
    my $comm    = $args{comm}    // 'perl';
    my $cmdline = $args{cmdline} // ['perl'];
    my $rss_kb  = $args{rss_kb}  // 1024;
    my $swap_kb = $args{swap_kb} // 0;
    my $start   = $args{starttime_ticks} // 1000;
    my $env     = $args{env} // {};

    my $dir = "$pid";
    $self->write_file( "$dir/comm",    "$comm\n" );
    $self->write_file( "$dir/cmdline", join( "\0", @$cmdline ) . "\0" );
    $self->write_file(
        "$dir/status",
        sprintf(
            "Name:\t%s\nPid:\t%d\nPPid:\t%d\nVmRSS:\t%d kB\nVmSwap:\t%d kB\n",
            $comm, $pid, $ppid, $rss_kb, $swap_kb
        )
    );

    # Build a /proc/PID/stat line with at least 22 fields where field 22
    # (1-indexed) is starttime. Field 2 (comm) is wrapped in parens.
    my @fields = ( $pid, "($comm)", 'S', $ppid );
    push @fields, 0 while @fields < 21;
    $fields[21] = $start;
    $self->write_file( "$dir/stat", join( ' ', @fields ) . "\n" );

    my $env_blob = join( "\0", map { "$_=$env->{$_}" } sort keys %$env );
    $self->write_file( "$dir/environ", $env_blob );
    return;
}

sub activate {
    my ($self) = @_;
    require Koha::StarmanWorkerWatcher::Proc;
    Koha::StarmanWorkerWatcher::Proc::set_proc_root( $self->{root} );
    return;
}

1;
