use Modern::Perl;
use Kavorka -all;
use utf8;
use POSIX;
use EV;
use AnyEvent;
use Coro;
use Coro::AnyEvent;
use AnyEvent::Socket;
use Coro::Handle;
use Coro::AIO;
use Digest::SHA1 qw(sha1);
use Encode;
use Bencode qw(bencode bdecode);
use LWP::Simple qw(get);
use Try::Tiny;
use File::Path 'rmtree';

# TODO:
# implement a server

fun file_content($file) {
    my $contents;
    open( my $fh, '<', $file ) or die "Cannot open torrent $file";
    {
        local $/;
        $contents = <$fh>;
    }
    close($fh);
    return $contents;
}

fun save_piece($content, $name) {
    my $fh = aio_open "pieces/$name", O_WRONLY | O_TRUNC | O_CREAT, 0666 or warn "Error: $!";
    aio_write $fh, 0, length($content), $content, 0 or warn "aio_write: $!";
    aio_close $fh;
}

my $torrent_file = 'ubuntu-20.04.2-live-server-amd64.iso.torrent';
my $torrent      = bdecode( file_content($torrent_file) );

my $file_name    = $torrent->{'info'}->{'name'};
my $file_length  = $torrent->{'info'}->{'length'};
my $piece_length = $torrent->{'info'}->{'piece length'};

my $info_hash  = Encode::encode( "ISO-8859-1", sha1( bencode( $torrent->{'info'} ) ) );
my $announce   = $torrent->{'announce'};
my $port       = 6881;
my $left       = $torrent->{'info'}->{'length'};
my $uploaded   = 0;
my $downloaded = 0;
my $peer_id    = "-AZ2200-6wFg2wk6wWLc";

my $tracker_request =
    $announce
  . "?info_hash="
  . $info_hash
  . "&peer_id="
  . $peer_id
  . "&port="
  . $port
  . "&uploaded="
  . $uploaded
  . "&downloaded="
  . $downloaded
  . "&left="
  . $left;

my $response = get($tracker_request) or die "Cannot connect to tracker";
my $tracker_response = bdecode($response);

my $peers = $tracker_response->{'peers'};

# $peers - {port, peert id, ip}

my $pstr = "BitTorrent protocol";
my $message = pack 'C1A*a8a20a20', length($pstr), $pstr, '',  $info_hash, $peer_id;

my $bitfields_num = length($torrent->{'info'}->{'pieces'}) / 20;
my $bitfield_num_bytes = 4 + 1 + ceil($bitfields_num / 8);

# length - 4 bytes, id - 1 bytes,
# $bitfields_num / 8 - bitfields bytes

mkdir( 'pieces' );

my $piece_channel = new Coro::Channel;
for my $n (0..$bitfields_num - 1) {
    $piece_channel->put($n);
}

for my $peer (@$peers) {
    async {
        tcp_connect $peer->{'ip'}, $peer->{'port'}, Coro::rouse_cb;
        my $fh = unblock +(Coro::rouse_wait)[0];

        my $buf;
        my $bitfield;

        try {
            $fh->syswrite($message);
        } catch {
              terminate;
        };

        $fh->sysread($buf, length($message));
        $fh->sysread($bitfield, $bitfield_num_bytes);

        my ($pstr_r, $reserved_r, $info_hash_r, $peer_id_r, $c) = unpack 'C/a a8 a20 a20 a*', $buf;
        my ($bitfield_length, $bitfield_id, $bitfield_data) = unpack 'N1 C1' . ' B' . $bitfields_num, $bitfield;

        if( !defined($bitfield_data) || !defined($info_hash_r) ) {
            terminate;
        }

        my @bitfield_array = split("", $bitfield_data);

        if( $info_hash eq $info_hash_r ) {
            my $interested = pack('Nc', 1, 2);
            my $choke_buf;

            $fh->syswrite($interested);
            $fh->sysread($choke_buf, 5);

            my ($length, $id) = unpack 'Nc', $choke_buf;
            if( $id == 1 ) {
                # Got Unchoke

                PIECELOOP: {
                    my $block_length = 16384;

                    if( $piece_channel->size == 0 ) {
                        terminate;
                    }
                    my $piece_index = $piece_channel->get;

                    if( defined($bitfield_array[$piece_index]) && $bitfield_array[$piece_index] == 1 ) {
                        # piece exists on the peer
                        my $piece_data = '';
                        my $piece_offset = 0;

                        BLOCKLOOP: {
                            my $block_buf;
                            my $block_buf_size = 4 + 1 + 4 + 4 + $block_length;

                            if( $piece_index == $bitfields_num - 1 ) {
                                # handle last piece
                                # $bitfields_num = number of pieces

                                my $extra = ($bitfields_num * $piece_length) - $file_length;
                                my $last_piece_length = $piece_length - $extra;

                                if ( $piece_offset == $last_piece_length ) {
                                    save_piece($piece_data, $piece_index);
                                    goto PIECELOOP;
                                }
                            }

                            if( $piece_offset == $piece_length ) {
                                save_piece($piece_data, $piece_index);
                                goto PIECELOOP;
                            }

                            my $request_pack = pack 'NNN', $piece_index, $piece_offset, $block_length;
                            my $request = pack 'Nca*', length($request_pack) + 1, 6, $request_pack;

                            $fh->syswrite($request);
                            $fh->sysread($block_buf, $block_buf_size);

                            my ($r_block_length, $r_block_id, $r_block_pack) = unpack 'Nca*', $block_buf;
                            #my $r_block_data_length = 16384; #($r_block_length - 9);


                            if(defined($r_block_id) && $r_block_id == 7) {
                                my $r_block_data_length = ($r_block_length - 9);
                                #my $r_block_data_length = 16384;

                                my $unpack = 'N N'. ' a' . $r_block_data_length;
                                my ($r_block_index, $r_block_offset, $r_block_data) = unpack $unpack, $r_block_pack;

                                $piece_data = $piece_data . $r_block_data;
                                $piece_offset = $piece_offset + $r_block_length - 9;
                                #$piece_offset = $piece_offset + $block_length;

                                # ...
                                goto BLOCKLOOP;
                            }
                            else {
                                goto BLOCKLOOP;
                            }
                        }
                    }
                    else {
                        # put back piece_index on piece channel
                        # let other workers download it
                        Coro::AnyEvent::sleep 1;
                        $piece_channel->put($piece_index);
                        goto PIECELOOP;
                    }
                }
            }
            elsif( $id == 0 ) {
                # Got Choke
                terminate;
            }
        }
    };
}

async {
    while (1) {
        Coro::AnyEvent::sleep 60;

        if( $piece_channel->size == 0 ) {
            say "Your download will complete in 5 minutes";
            Coro::AnyEvent::sleep 300;
            # wait 5 minutes for the running Coro's to terminate

            opendir(Dir, 'pieces') || die "Can't open directory pieces: $!\n";
            my @list = readdir(Dir);
            closedir(Dir);

            shift(@list);
            shift(@list);

            my @sort_files = sort { $a <=> $b } @list;
            my $data = '';

            for my $file (0..$#sort_files) {
                my $file_piece_content = file_content( 'pieces/' . $sort_files[$file]);
                $data = $data . $file_piece_content;
            }

            open ( my $of, '>', $file_name) or die "Cannot write to $file_name";
            print $of $data;
            close($of);

            rmtree([ "pieces" ]);

            say "Download Complete";

            # https://askubuntu.com/questions/329704/syslinux-no-default-or-ui-configuration-directive-found

            terminate;
        }
    }
};

cede;
EV::loop();
