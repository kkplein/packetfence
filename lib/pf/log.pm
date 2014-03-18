package pf::log::trapper;
use Log::Log4perl;
Log::Log4perl->wrapper_register(__PACKAGE__);

sub TIEHANDLE {
    my $class = shift;
    my $level = shift;
    bless [Log::Log4perl->get_logger(),$level], $class;
}

sub OPEN {}

sub PRINT {
    my $self = shift;
    local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
    $self->[0]->log($self->[1],@_);
}
1;

package pf::log;

=head1 NAME

pf::log add documentation

=cut

=head1 DESCRIPTION

pf::log

=cut

use strict;
use warnings;
use Log::Log4perl;
use Log::Log4perl::Level;
use pf::file_paths;
use File::Basename qw(basename);

Log::Log4perl->wrapper_register(__PACKAGE__);
sub import {
    my ($self,%args) = @_;
    my ($package, $filename, $line) = caller;
    unless(Log::Log4perl->initialized) {
        my $service = $args{service} if defined $args{service};
        if($service) {
            Log::Log4perl->init_and_watch("$log_conf_dir/${service}.conf",5 * 60);
            Log::Log4perl::MDC->put( 'proc', $service );
            tie *STDERR,'pf::log::trapper',$ERROR;
            tie *STDOUT,'pf::log::trapper',$DEBUG;
        } else {
            Log::Log4perl->init($log_config_file);
            Log::Log4perl::MDC->put( 'proc', basename($0) );
        }
    }
    Log::Log4perl::MDC->put( 'tid', $$ );
    {
        no strict qw(refs);
        *{"${package}::get_logger"} = \&get_logger;
    }
}

sub get_logger { Log::Log4perl->get_logger(@_); }

sub redirectStdIo {
}

=head1 AUTHOR

Inverse inc. <info@inverse.ca>


=head1 COPYRIGHT

Copyright (C) 2005-2013 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and::or
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

1;

