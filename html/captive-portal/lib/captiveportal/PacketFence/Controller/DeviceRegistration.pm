package captiveportal::PacketFence::Controller::DeviceRegistration;;
use Moose;
use namespace::autoclean;
use pf::Authentication::constants;
use pf::config qw(%Config);
use pf::constants;
use pf::log;
use pf::node;
use pf::util;
use pf::error qw(is_success);
use pf::web;
use pf::enforcement qw(reevaluate_access);
use fingerbank::DB_Factory;

BEGIN { extends 'captiveportal::Base::Controller'; }

__PACKAGE__->config( namespace => 'device-registration' );

=head1 NAME

captiveportal::PacketFence::Controller::DeviceRegistration - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

sub auto : Private {
    my ( $self, $c ) = @_;
    if (isdisabled( $Config{'device_registration'}{'status'} ) )
    {
        $self->showError($c,"Device registration module is not enabled" );
        $c->detach;
    }
    return 1;
}

=head2 index

=cut

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;
    my $logger  = $c->log;
    my $pid     = $c->user_session->{"username"};
    my $request = $c->request;

    # See if user is trying to login and if is not already authenticated
    if ( ( !$pid ) ) {
        # Verify if user is authenticated
        $c->forward('userNotLoggedIn');
    } elsif ( $request->param('cancel') ) {
        $c->user_session({});
        $c->detach('login');
    }
    if ( $request->method eq 'POST' && $request->param('device_mac') ) {
        # User is authenticated and requesting to register a device
        my $device_mac = clean_mac($request->param('device_mac'));
        my $device_type;
        $device_type = $request->param('console_type') if ( defined($request->param('console_type')) );

        if(valid_mac($device_mac)) {
            # Register device
            $c->forward('registerNode', [ $pid, $device_mac, $device_type ]);
        }
        $c->stash(txt_auth_error => "Please verify the provided MAC address.");
    }
    # User is authenticated so display registration page
    $c->stash(title => "Registration", template => 'device-registration/registration.html');
}

=head2 gaming_registration

Backwards compatability

/gaming-registration

=cut

sub gaming_registration: Path('/gaming-registration') {
    my ( $self, $c ) = @_;
    $c->forward('index');
}


=head2 userNotLoggedIn

=cut

sub userNotLoggedIn : Private {
    my ($self, $c) = @_;
    my $request = $c->request;
    my $username = $request->param('username');
    my $password = $request->param('password');
    if ( all_defined( $username, $password ) ) {
        $c->forward(Authenticate => 'authenticationLogin');
        if ($c->has_errors) {
            $c->detach('login');
        }
    } else {
        $c->detach('login');
    }
}

=head2 login

Display the device registration login

=cut

sub login : Local : Args(0) {
    my ( $self, $c ) = @_;
    if ( $c->has_errors ) {
        $c->stash->{txt_auth_error} = join(' ', grep { ref ($_) eq '' } @{$c->error});
        $c->clear_errors;
    }
    $c->stash( title => "Login", template => 'device-registration/login.html' );
}

sub landing : Local : Args(0) {
    my ( $self, $c ) = @_;
    $c->stash( title => "Device registration landing", template => 'device-registration/registration.html' );
}

sub registerNode : Private {
    my ( $self, $c, $pid, $mac, $type ) = @_;
    my $logger = $c->log;
    if ( is_allowed($mac) && valid_mac($mac) ) {
        my ($node) = node_view($mac);
        if( $node && $node->{status} ne $pf::node::STATUS_UNREGISTERED ) {
            $c->stash( status_msg_error => ["%s is already registered or pending to be registered. Please verify MAC address if correct contact your network administrator", $mac]);
            $c->detach('index');
        } else {
            my $session = $c->user_session;
            my $source_id = $session->{source_id};
            my %info;
            my $params = { username => $pid };
            $c->stash->{device_mac} = $mac;
            # Get role for device registration
            my $role =
              $Config{'device_registration'}{'role'};
            if ($role) {
                $logger->debug("Device registration role is $role (from pf.conf)");
            } else {
                # Use role of user
                $role = pf::authentication::match( $source_id, $params , $Actions::SET_ROLE);
                $logger->debug("Gaming devices role is $role (from username $pid)");
            }

            my $unregdate = pf::authentication::match( $source_id, $params, $Actions::SET_UNREG_DATE);
            if ( defined $unregdate ) {
                $logger->debug("Got unregdate $unregdate for username $pid");
                $info{unregdate} = $unregdate;
            }
            my $time_balance = &pf::authentication::match( $source_id, $params, $Actions::SET_TIME_BALANCE);
            if ( defined $time_balance ) {
                $logger->debug("Got time balance $time_balance for username $pid");
                $info{time_balance} = pf::util::normalize_time($time_balance);
            }
            my $bandwidth_balance = &pf::authentication::match( $source_id, $params, $Actions::SET_BANDWIDTH_BALANCE);

            if ( defined $bandwidth_balance ) {
                $logger->debug("Got bandwidth balance $bandwidth_balance for username $pid");
                $info{bandwidth_balance} = pf::util::unpretty_bandwidth($bandwidth_balance);
            }
            $info{'category'} = $role if ( defined $role );
            $info{'auto_registered'} = 1;
            $info{'mac'} = $mac;
            $info{'pid'} = $pid;
            $info{'notes'} = $type if ( defined($type) );
            $c->portalSession->guestNodeMac($mac);
            node_modify($mac, status => "reg", %info);
            reevaluate_access($mac, 'manage_register');
            $c->stash( status_msg  => [ "The MAC address %s has been successfully registered.", $mac ]);
            $c->detach('Controller::Status', 'index');
        }
    } else {
        $c->stash( status_msg_error => [ "The provided MAC address %s is not allowed to be registered using this self-service page.", $mac ]);
        $c->detach('landing');
    }
}

=item mac_vendor_id

Get the matching mac_vendor_id from Fingerbank

=cut

sub mac_vendor_id {
    my ($mac) = @_; 
    my $logger = get_logger();

    my ($status, $result) = fingerbank::Model::MAC_Vendor->find([{ mac => $mac }, {columns => ['id']}]);

    if(is_success($status)){
        return $result->id;
    }else {
        $logger->debug("Cannot find mac vendor ".$mac." in the database");
    }
}

=item device_from_mac_vendor

Get the matching device infos by mac vendor from Fingerbank

=cut

sub device_from_mac_vendor {
    my ($mac_vendor_id) = @_; 
    my $logger = get_logger();

    for my $schema (("Local", "Upstream")) { 
        my $db = fingerbank::DB_Factory->instantiate(schema => $schema);
        my $view_class = "fingerbank::Schema::".$schema."::CombinationMacVendorByDevice";
        my $bind_params = $view_class->view_bind_params([$mac_vendor_id]);
        my $result = $db->handle->resultset('CombinationMacVendorByDevice')->search({}, { bind => $bind_params })->first;
        if ($result) {
            my $device_id = $result->device_id;
            $logger->info("Found $device_id for MAC vendor $mac_vendor_id");
            return $device_id;
        }
    } 

    $logger->debug("Cannot find matching device id for this mac vendor id ".$mac_vendor_id." in the database");
    return undef;
}

=item is_allowed 

Verify 

=cut 

sub is_allowed {
    my ($mac) = @_;
    $mac =~ s/O/0/i;
    my $logger = get_logger();
    my @oses = @{$Config{'device_registration'}{'allowed_devices'}};

    # If no oses are defined then it will not match any oses
    return $FALSE if @oses == 0;

    # Verify if the device is existing in the table node and if it's device_type is allowed
    my $node = node_view($mac);
    my $device_type = $node->{device_type};
    for my $id (@oses) {
        my $endpoint = fingerbank::Model::Endpoint->new(name => $device_type, version => undef, score => undef);
        if ( defined($device_type) && $endpoint->is_a_by_id($id)) {
            $logger->debug("The devices type ".$device_type." is authorized to be registered via the device-registration module");
            return $TRUE;
        }
    }

    $mac =~ s/://g;
    my $mac_vendor = substr($mac, 0,6);
    my $mac_vendor_id = mac_vendor_id($mac_vendor);
    my $device_id = device_from_mac_vendor($mac_vendor_id);
    my ($status, $result) = fingerbank::Model::Device->find([{ id => $device_id}, {columns => ['name']}]);

    # We are loading the fingerbank endpoint model to verify if the device id is matching as a parent or child
    if (is_success($status)){
        my $device_name = $result->name;
        my $endpoint = fingerbank::Model::Endpoint->new(name => $device_name, version => undef, score => undef);

        for my $id (@oses) {
            if ($endpoint->is_a_by_id($id)) {
                $logger->debug("The devices type ".$device_name." is authorized to be registered via the device-registration module");
                return $TRUE;
            }
        }
    } else {
        $logger->debug("Cannot find a matching device name for this device id ".$device_id." .");
        return $FALSE;
    }
}

=head2 logout

allow user to logout

=cut

sub logout : Local {
    my ( $self, $c ) = @_;
    $c->user_session({});
    $c->forward('index');
}
=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2017 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

__PACKAGE__->meta->make_immutable;

1;
