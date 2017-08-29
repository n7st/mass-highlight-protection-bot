package MassHighlight::Event;

use Carp;
use Moose;
use POE qw(Component::IRC::State Component::IRC::Plugin::NickServID Component::SSLify);
use Reflex::POE::Session;
use Reflex::Trait::Watched qw(watches);

extends 'Reflex::Base';

our $VERSION = 0.01;

################################################################################

has config => (is => 'rw', isa => 'HashRef', required => 1);

has channels => (is => 'rw', isa => 'HashRef', default => sub { {} });

has component       => (is => 'rw', isa => 'POE::Component::IRC::State', lazy_build => 1);
has actual_nickname => (is => 'rw', isa => 'Str',                        lazy_build => 1);

has default_highlight_limit   => (is => 'ro', isa => 'Int', default => 10);
has default_min_filter_length => (is => 'ro', isa => 'Int', default => 20);
has default_min_word_count    => (is => 'ro', isa => 'Int', default => 5);

watches poco_watcher => (is => 'rw', isa => 'Reflex::POE::Session', role => 'poco');

################################################################################

sub BUILD {
    my $self = shift;

    $self->poco_watcher(Reflex::POE::Session->new({
        sid => $self->component->session_id,
    }));

    if ($self->config->{nickserv_password}) {
        $self->component->plugin_add('NickServID', POE::Component::IRC::Plugin::NickServID->new(
            Password => $self->config->{nickserv_password},
        ));
    }

    $self->run_within_session(sub {
        # _start event (POE::Component::IRC::State)
        $self->component->yield(register => 'all');
        $self->component->yield(connect => {});
    });

    return 1;
}

sub on_poco_irc_001 {
    my $self  = shift;
    my $event = shift;

    $self->actual_nickname($self->component->{INFO}->{RealNick});

    foreach (@{$self->config->{channels}}) {
        $self->component->yield(join => $_)
    }

    return 1;
}

sub on_poco_irc_public {
    my $self  = shift;
    my $event = shift;

    my $channel    = $event->{args}->[1]->[0];
    my $message    = $event->{args}->[2];
    my $word_count = () = $message =~ m/\s/g;
    my $min_len    = $self->config->{min_filter_len} // $self->default_min_filter_length;
    my $min_words  = $self->config->{min_word_count} // $self->default_min_word_count;

    if (!length($message) >= $min_len || $word_count <= $min_words) {
        # Don't do heavy lifting for short messages
        return 1;
    }

    my @nicknames = grep { $self->channels->{$channel}->{$_} == 1 } keys %{$self->channels->{$channel}};

    if (!@nicknames) {
        return;
    }

    my $highlight_limit = $self->config->{highlight_limit} // $self->default_highlight_limit;
    my $nickname        = $self->_nick_from_host_string($event->{args}->[0]);

    my %args = map { $_ => 1 } split / /, $message;
    my %seen;

    foreach my $nick (@nicknames) {
        if ($args{$nick}) {
            $seen{$nick} = 1;
        }
    }

    my ($hostname) = $event->{args}->[0] =~ m/@(.+)$/;

    if ($hostname && scalar keys %seen >= $highlight_limit) {
        if ($self->_has_channel_access($channel)) {
            $self->component->yield('kick' => $channel => $nickname => 'Mass highlighting');
            $self->component->yield('mode' => "${channel} +b *!*\@${hostname}");
        } else {
            carp 'I don\'t have access to perform a ban!';
        }
    }

    return 1;
}

sub on_poco_irc_chan_sync {
    my $self  = shift;
    my $event = shift;

    # The bot joined a channel and a sync of its information was completed.
    # This is here rather than irc_join because /NAMES takes a while.

    my $channel = $event->{args}->[0];
    my @nicks   = $self->component->channel_list($channel);

    my $channel_info = $self->channels;

    $channel_info->{$channel} = { map { $_ => 1 } @nicks };

    $self->channels($channel_info);

    return 1;
}

sub on_poco_irc_nick {
    my $self  = shift;
    my $event = shift;

    my ($old_nick) = $self->_nick_from_host_string($event->{args}->[0]);

    if ($old_nick eq $self->actual_nickname) {
        # Bot's nickname was changed
        $self->actual_nickname($event->{args}->[1]);
    }

    return $self->_update_channel_nick_list({
        channel  => $event->{args}->[2]->[0],
        nickname => {
            new => $event->{args}->[1],
            old => $old_nick,
        },
    });
}

sub on_poco_irc_kick {
    my $self  = shift;
    my $event = shift;

    return $self->_update_channel_nick_list({
        channel  => $event->{args}->[1],
        nickname => {
            old => $event->{args}->[2],
        },
    });
}

sub on_poco_irc_disconnected {
    my $self  = shift;
    my $event = shift;

    # Reconnect?

    return 1;
}

sub on_poco_irc_nick_sync {
    my $self  = shift;
    my $event = shift;

    # An individual user joined the channel

    return $self->_update_channel_nick_list({
        channel  => $event->{args}->[1],
        nickname => {
            new => $event->{args}->[0],
        },
    });
}

################################################################################

sub _has_channel_access {
    my $self    = shift;
    my $channel = shift;

    # Fall through until we find access the bot has (or return false)

    return $self->component->is_channel_admin($channel, $self->actual_nickname) ||
        $self->component->is_channel_halfop($channel, $self->actual_nickname)   ||
        $self->component->is_channel_operator($channel, $self->actual_nickname) ||
        $self->component->is_channel_owner($channel, $self->actual_nickname)    ||
        $self->component->is_operator($self->actual_nickname);
}

sub _nick_from_host_string {
    my $self  = shift;
    my $input = shift;

    my ($nickname) = $input =~ m/^(.+)!/;

    return $nickname;
}

sub _update_channel_nick_list {
    my $self = shift;
    my $args = shift;

    my $channel_info = $self->channels;

    if ($args->{nickname}->{new}) {
        $channel_info->{$args->{channel}}->{$args->{nickname}->{new}} = 1;
    }

    if ($args->{nickname}->{old}) {
        $channel_info->{$args->{channel}}->{$args->{nickname}->{old}} = 0;
    }

    $self->channels($channel_info);

    return 1;
}

################################################################################

sub _build_actual_nickname {
    my $self = shift;

    # Default to expected nickname
    return $self->config->{nickname};
}

sub _build_component {
    my $self = shift;

    my %required_config_opts = (
        ircname  => 1,
        nickname => 1,
        server   => 1,
        port     => 1,
    );

    foreach (keys %required_config_opts) {
        if (!$self->config->{$_}) {
            croak "Missing config option: $_";
        }
    }

    return POE::Component::IRC::State->spawn(
        server   => $self->config->{server},
        port     => $self->config->{port},
        nick     => $self->config->{nickname},
        ircname  => $self->config->{ircname},
        username => $self->config->{ident},
        debug    => 1,
        UseSSL   => $self->config->{ssl},
    ) || croak 'Bot spawn failure';
}

################################################################################

no Moose;
__PACKAGE__->meta->make_immutable();
1;

