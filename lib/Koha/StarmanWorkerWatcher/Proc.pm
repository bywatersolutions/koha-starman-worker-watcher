package Koha::StarmanWorkerWatcher::Proc;

use Modern::Perl;

use Exporter 'import';
our @EXPORT_OK = qw(
    list_pids
    read_proc_file
    read_cmdline
    read_comm
    read_status
    read_stat
    read_environ
    btime
    clock_ticks
    worker_info
    is_starman_worker
);

my $PROC = $ENV{KSWW_PROC_ROOT} // '/proc';

sub _proc_root { return $PROC }

sub set_proc_root {
    my ($root) = @_;
    $PROC = $root;
    return;
}

sub list_pids {
    my $root = _proc_root();
    opendir( my $dh, $root ) or return ();
    my @pids = sort { $a <=> $b } grep { /\A[0-9]+\z/ } readdir($dh);
    closedir($dh);
    return @pids;
}

sub read_proc_file {
    my ( $pid, $name ) = @_;
    my $path = _proc_root() . "/$pid/$name";
    open( my $fh, '<', $path ) or return;
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

sub read_cmdline {
    my ($pid) = @_;
    my $raw = read_proc_file( $pid, 'cmdline' );
    return [] unless defined $raw && length $raw;
    chop $raw if substr( $raw, -1 ) eq "\0";
    return [ split /\0/, $raw ];
}

sub read_comm {
    my ($pid) = @_;
    my $raw = read_proc_file( $pid, 'comm' );
    return '' unless defined $raw;
    chomp $raw;
    return $raw;
}

sub read_status {
    my ($pid) = @_;
    my $raw = read_proc_file( $pid, 'status' );
    return {} unless defined $raw;
    my %status;
    for my $line ( split /\n/, $raw ) {
        next unless $line =~ /\A([^:]+):\s*(.*)\z/;
        $status{$1} = $2;
    }
    return \%status;
}

sub read_stat {
    my ($pid) = @_;
    my $raw = read_proc_file( $pid, 'stat' );
    return unless defined $raw;

    # The second field (comm) is wrapped in parens and may contain spaces.
    my ( $first, $rest ) = $raw =~ /\A(\d+)\s+\((.*)\)\s+(.*)\z/s
        ? ( $1, $3 )
        : return;
    my @fields = ( $first, split /\s+/, $rest );

    # Field numbering per proc(5): field 22 is starttime (0-indexed 21,
    # but our array is missing comm so the offsets shift by one).
    # We rebuild: index 0 = pid, index 1 = state, ..., index 21 = starttime
    # but since we dropped comm, starttime is at our index 20.
    return {
        pid       => $fields[0],
        state     => $fields[1],
        ppid      => $fields[2],
        starttime => $fields[20],
    };
}

sub read_environ {
    my ($pid) = @_;
    my $raw = read_proc_file( $pid, 'environ' );
    return {} unless defined $raw;
    my %env;
    for my $entry ( split /\0/, $raw ) {
        next unless $entry =~ /\A([^=]+)=(.*)\z/s;
        $env{$1} = $2;
    }
    return \%env;
}

sub btime {
    open( my $fh, '<', _proc_root() . '/stat' ) or return 0;
    while ( my $line = <$fh> ) {
        if ( $line =~ /\Abtime\s+(\d+)/ ) {
            close($fh);
            return $1 + 0;
        }
    }
    close($fh);
    return 0;
}

sub clock_ticks {
    my $ticks = 100;
    my $out   = `getconf CLK_TCK 2>/dev/null`;
    if ( defined $out && $out =~ /(\d+)/ ) {
        $ticks = $1 + 0;
    }
    return $ticks;
}

sub is_starman_worker {
    my ($info) = @_;
    return 0 unless $info;
    my $cmdline = $info->{cmdline} // [];
    my $joined  = join( ' ', @$cmdline );

    # Idle worker: proctitle set by Starman to "starman worker ..."
    return 1 if $joined =~ /\Astarman\s+worker\b/;

    # Active worker running a .pl script through Plack::App::CGIBin:
    # proctitle gets replaced with the script path. We rely on the parent
    # being "starman master" to confirm.
    return 1 if $info->{parent_is_starman_master};

    return 0;
}

sub worker_info {
    my ($pid) = @_;

    my $cmdline = read_cmdline($pid);
    return unless @$cmdline;

    my $stat = read_stat($pid);
    return unless $stat;

    my $status = read_status($pid);
    my $comm   = read_comm($pid);

    my $rss_kb  = 0;
    my $swap_kb = 0;
    if ( ( $status->{VmRSS}  // '' ) =~ /(\d+)/ ) { $rss_kb  = $1 + 0 }
    if ( ( $status->{VmSwap} // '' ) =~ /(\d+)/ ) { $swap_kb = $1 + 0 }

    my $parent_cmdline = read_cmdline( $stat->{ppid} ) // [];
    my $parent_joined  = join( ' ', @$parent_cmdline );
    my $parent_is_master = $parent_joined =~ /starman\s+master/ ? 1 : 0;

    my $info = {
        pid                      => $pid + 0,
        comm                     => $comm,
        cmdline                  => $cmdline,
        ppid                     => $stat->{ppid},
        starttime_ticks          => $stat->{starttime},
        rss_kb                   => $rss_kb,
        swap_kb                  => $swap_kb,
        parent_is_starman_master => $parent_is_master,
    };

    $info->{script}   = _detect_script($info);
    $info->{instance} = _detect_instance( $pid, $stat->{ppid} );

    return $info;
}

sub _detect_script {
    my ($info) = @_;
    my $first = $info->{cmdline}->[0] // '';

    # Idle Starman worker has proctitle "starman worker ..."
    return '' if $first =~ /\Astarman\b/;
    return '' if $first eq '';

    # When running a script via Plack::App::CGIBin, Starman replaces the
    # proctitle with the script path.
    return $first;
}

sub _detect_instance {
    my ( $pid, $ppid ) = @_;

    my $env      = read_environ($pid);
    my $koha_env = $env->{KOHA_CONF} // '';
    if ( $koha_env =~ m{/etc/koha/sites/([^/]+)/} ) {
        return $1;
    }

    # Fall back to walking up until we find a starman master whose cmdline
    # references a koha-conf.xml path.
    my $cur = $ppid;
    my $hops = 0;
    while ( $cur && $cur > 1 && $hops++ < 4 ) {
        my $parent_cmdline = read_cmdline($cur) // [];
        my $joined = join( ' ', @$parent_cmdline );
        if ( $joined =~ m{/etc/koha/sites/([^/]+)/} ) {
            return $1;
        }
        my $pstat = read_stat($cur);
        last unless $pstat;
        $cur = $pstat->{ppid};
    }

    return 'unknown';
}

1;
