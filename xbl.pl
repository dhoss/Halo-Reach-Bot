#!/usr/bin/perl

use warnings;
use strict;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::HTTP;
use XML::Simple;
use Config::JFDI;;

my $c = Config::JFDI->new(file => "./xbl.yml", quiet_deprecation => 1 );
my $config = $c->get;

my $network = $config->{network} || die 'no network specified in xbl.yml';
my $channel = '#'.$config->{channel} || die 'no channel specified in xbl.yml';
my $port = $config->{port} || die 'no port specified in xbl.yml';
my $nick = $config->{nick} || die 'no nick specified in xbl.yml';
my $interval = $config->{interval} || '120';

my @gts = @{$config->{gamertags}};

my $mobbers = {};
my $cv = AnyEvent->condvar;

my $timer;
my $con = new AnyEvent::IRC::Client;

$con->reg_cb (connect => sub {
   my ($con, $err) = @_;
   if (defined $err) {
      warn "connect error: $err\n";
      return;
   }
});

$con->reg_cb(registered => sub {
    $timer = AnyEvent->timer(
        after => 1,
        interval => $interval,
        cb => sub {
            update_infos();
        },
    );
    
    $con->send_srv(
        JOIN => $channel,
    );
});

$con->reg_cb(irc_privmsg => sub {
    my ($self, $msg) = @_;

    my $chan = $msg->{params}->[0];
    my $from = $msg->{prefix};

    my $txt = $msg->{params}->[-1];
    if ($txt =~ /^\s*\!reach/i) {
        foreach my $gt (@gts) {
            my $game_item = $mobbers->{$gt}->{game};
            
            my $game_id = $game_item->{guid};
            my $game_info = $game_item->{description};
            my $killdeath = $game_item->{'haloreach:spread'};

            $con->send_srv(
                PRIVMSG => $channel,
                $gt."'s last game: ".ucfirst($game_info).", their spread was $killdeath - $game_id"
            );
        }
    }
});
    

$con->reg_cb (disconnect => sub { warn "Disconnected\n"; undef $timer; $cv->broadcast });

$con->connect($network, $port, { nick => $nick });
$cv->wait;
$con->disconnect;

sub update_infos {
    foreach my $gt_orig (@gts) {
        my $gt = $gt_orig;
        $gt =~ s/ /+/g;
        
        my $req = http_get "http://www.bungie.net/stats/reach/rssgamehistory.ashx?vc=0&player=$gt&page=0", sub {        
            my ($body, $hdr) = @_;
            
            my $xml = XMLin($body);
            unless ($xml) {
                warn "Failed to get info for $gt_orig";
                return;
            }
                        
            $mobbers->{$gt_orig} ||= {};
            my $info = $mobbers->{$gt_orig};
            my $old_game_id = $info->{game}->{guid};

            my $game_array = $xml->{channel}->{item};
            my $game_item = shift @$game_array;        
            my $game_id = $game_item->{guid};
            my $game_info = $game_item->{description};
            my $killdeath = $game_item->{'haloreach:spread'};
                        
            if (defined $old_game_id) {
                if ($old_game_id ne $game_id) {
                    # status changed
                    $con->send_srv(
                        PRIVMSG => $channel,
                        "$gt_orig played ".ucfirst($game_info).", their spread was $killdeath - $game_id"
                    );
                }
            }
            
            $mobbers->{$gt_orig}->{game} = $game_item;
        };
        
        $mobbers->{$gt_orig}->{req} = $req;
    }
}
