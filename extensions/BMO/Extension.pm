# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the BMO Bugzilla Extension.
#
# The Initial Developer of the Original Code is Gervase Markham.
# Portions created by the Initial Developer are Copyright (C) 2010 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Gervase Markham <gerv@gerv.net>

package Bugzilla::Extension::BMO;
use strict;
use base qw(Bugzilla::Extension);

use Bugzilla::Extension::BMO::Data qw($cf_visible_in_products
                                      %group_to_cc_map
                                      $blocking_trusted_setters
                                      $blocking_trusted_requesters
                                      $status_trusted_wanters
                                      %always_fileable_group);

use Bugzilla::Field;
use Bugzilla::Constants;
use Bugzilla::Status;
use Bugzilla::User::Setting;
use Tie::IxHash;
use List::MoreUtils qw(first_index);

our $VERSION = '0.1';

sub template_before_process {
    my ($self, $args) = @_;
    my $file = $args->{'file'};
    my $vars = $args->{'vars'};
    
    $vars->{'cf_hidden_in_product'} = \&cf_hidden_in_product;
    
    if ($file =~ /^list\/list/) {
        # Purpose: enable correct sorting of list table
        # Matched to changes in list/table.html.tmpl
        my %db_order_column_name_map = (
            'map_components.name' => 'component',
            'map_products.name' => 'product',
            'map_reporter.login_name' => 'reporter',
            'map_assigned_to.login_name' => 'assigned_to',
            'delta_ts' => 'opendate',
            'creation_ts' => 'changeddate',
        );

        my @orderstrings = split(/,\s*/, $vars->{'order'});
        
        # contains field names of the columns being used to sort the table.
        my @order_columns;
        foreach my $o (@orderstrings) {
            $o =~ s/bugs.//;
            $o = $db_order_column_name_map{$o} if 
                                grep($_ eq $o, keys(%db_order_column_name_map));
            next if (grep($_ eq $o, @order_columns));
            push(@order_columns, $o);
        }

        $vars->{'order_columns'} = \@order_columns;
        
        # fields that have a custom sortkey. (So they are correctly sorted 
        # when using js)
        my @sortkey_fields = qw(milestones bug_status resolution bug_severity 
                                priority rep_platform op_sys);

        my %columns_sortkey;
        foreach my $field (@sortkey_fields) {
            $columns_sortkey{$field} = get_field_values_sort_key($field);
        }

        $vars->{'columns_sortkey'} = \%columns_sortkey;

        # Purpose: Use only enabled milestones on mass change page.
        #
        # This requires a special var because $vars->{'one_product'}, for 
        # some reason, is only there if the user can enter bugs in the product.
        # I'm not convinced that this is the same thing as being able to change
        # the TM using mass change, so I've had to put it in the vars hash
        # unconditionally in a new var for this check.
        my $one_product = $vars->{'one_product_unconditional'};
        if ($one_product && Bugzilla->params->{'usetargetmilestone'}) {
            my @milestones = grep($_->is_active, @{$one_product->milestones});
            $vars->{'targetmilestones'} = [map($_->name, @milestones )];
        }
    }
    elsif ($file =~ /^create\/create/) {
        if (!$vars->{'cloned_bug_id'}) {
            # Allow status whiteboard values to be bookmarked
            $vars->{'status_whiteboard'} = 
                               Bugzilla->cgi->param('status_whiteboard') || "";
        }
        
        my %default = %{ $vars->{'default'} };
        
        # hack to allow the bug entry templates to use check_can_change_field 
        # to see if various field values should be available to the current 
        # user
        $Bugzilla::FakeBug::check_can_change_field = sub { 
            return Bugzilla::Bug::check_can_change_field(\%default, @_);
        };
        $Bugzilla::FakeBug::_changes_everconfirmed = sub { 
            return Bugzilla::Bug::_changes_everconfirmed(\%default, @_);
        };
        $Bugzilla::FakeBug::everconfirmed = sub { 
            return ($default{'status'} == 'UNCONFIRMED') ? 0 : 1;
        };
        bless \%default, 'Bugzilla::FakeBug';
        
        # XXX necessary?
        $vars->{'default'} = \%default;
        
        # Purpose: for pretty-product-chooser
        $vars->{'format'} = Bugzilla->cgi->param('format');      
    }
    elsif ($file =~ /^pages\//) {
        $vars->{'bzr_history'} = sub { 
            return `cd /data/www/bugzilla.mozilla.org; /usr/bin/bzr log -n0 -rlast:10..`;
        };
    }
}

sub get_field_values_sort_key {
    my ($field) = @_;
    my $dbh = Bugzilla->dbh;
    my $fields = $dbh->selectall_arrayref(
         "SELECT value, sortkey FROM $field
        ORDER BY sortkey, value");

    my %field_values;
    foreach my $field (@$fields) {
        my ($value, $sortkey) = @$field;
        $field_values{$value} = $sortkey;
    }
    return \%field_values;
}

sub cf_hidden_in_product {
    my ($field_name, $product_name, $component_name) = @_;
    
    $component_name ||= "";
    
    foreach my $field_re (keys %$cf_visible_in_products) {
        my $products = $cf_visible_in_products->{$field_re};
        
        if ($field_name =~ $field_re) {
            my $components = $products->{$product_name};
            if (!defined($components) ||
                (scalar @{ $components } > 0 &&
                 (first_index {$_ eq $component_name} @$components) == -1))
            {
                return 1;
            }
            else {
                return 0;
            }
        }
    }
    
    return 0;
}

# Purpose: CC certain email addresses on bugmail when a bug is added or 
# removed from a particular group.
# XXX Check this works for new bugs too...
sub bugmail_recipients {
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
    my $recipients = $args->{'recipients'};
    my $diffs = $args->{'diffs'};
    
    foreach my $ref (@$diffs) {
        my ($who, $whoname, $what, $when, 
            $old, $new, $attachid, $fieldname) = (@$ref);
        
        # If the security bit is being set or unset, CC the appropriate
        # security list. This is to make sure security bugs don't get lost.
        if ($fieldname eq "bug_group") {
            foreach my $group (keys %group_to_cc_map) {
                if ($old =~ $group || $new =~ $group) {
                    my $id = login_to_id($group_to_cc_map{$group});
                    $recipients->{$id}->{+REL_CC} = 1;
                }
            }
        }
    }
}    

sub object_end_of_create {
    my ($self, $args) = @_;
    my $class = $args->{'class'};
    my $object = $args->{'object'};
 
    # Purpose: prevent bugmail ever being sent to known-invalid addresses 
    if ($class->isa('Bugzilla::User')) {
        if ($object->email =~ /(bugs|\.tld)$/) {
            $object->set_disable_mail(1);
        }
    }
    # XXX remove now?
    elsif ($class->isa('Bugzilla::Milestone')) {
        $object->{'is_active'} = sub { return $_[0]->{'is_active'} };
        $object->{'is_searchable'} = sub { return $_[0]->{'is_searchable'} };
    }
}

sub check_trusted {
    my ($field, $trusted, $priv_results) = @_;
    
    my $needed_group = $trusted->{'_default'} || "";
    foreach my $dfield (keys %$trusted) {
        if ($field =~ $dfield) {
            $needed_group = $trusted->{dfield};
        }
    }
    if ($needed_group && !Bugzilla->user->in_group($needed_group)) {
        push (@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
    }              
}

sub bug_check_can_change_field {
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
    my $field = $args->{'field'};
    my $new_value = $args->{'new_value'};
    my $old_value = $args->{'old_value'};
    my $priv_results = $args->{'priv_results'};
    my $user = Bugzilla->user;
    
    # Purpose: Only users in the appropriate drivers group can change the 
    # cf_blocking_* fields.
    if ($field =~ /^cf_blocking_/) {
        unless ($new_value eq '---' || 
                $new_value eq '?' || 
                ($new_value eq '1' && $old_value eq '0')) 
        {
            check_trusted($field, $blocking_trusted_setters, $priv_results);
        }
        
        if ($new_value eq '?') {
            check_trusted($field, $blocking_trusted_requesters, 
                                  $priv_results);
        }        
    }

    if ($field =~ /^cf_status_/) {
        # Only drivers can set wanted.
        if ($new_value eq 'wanted') {
            check_trusted($field, $status_trusted_wanters, $priv_results);
        }
        
        # Require 'canconfirm' to change anything else
        if (!$user->in_group('canconfirm', $bug->{'product_id'})) {
            push (@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
        }
    }

    # The EXPIRED resolution should only be settable by gerv.
    if ($field eq 'resolution' && $new_value eq 'EXPIRED') {
        if ($user->login ne 'gerv@mozilla.org') {
            push (@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
        }
    }

    # Canconfirm is really "cantriage"; users with canconfirm can also mark 
    # bugs as DUPLICATE, WORKSFORME, and INCOMPLETE.
    if ($user->in_group('canconfirm', $bug->{'product_id'})) {
        if ($field eq 'bug_status'
            && is_open_state($old_value)
            && !is_open_state($new_value))
        {
            push (@$priv_results, PRIVILEGES_REQUIRED_NONE);
        }
        elsif ($field eq 'resolution' && 
               ($new_value eq 'DUPLICATE' ||
                $new_value eq 'WORKSFORME' ||
                $new_value eq 'INCOMPLETE'))
        {
            push (@$priv_results, PRIVILEGES_REQUIRED_NONE);
        }
    }
}

# Purpose: make milestones have an "active" and a "searchable" flag.
BEGIN { 
    *Bugzilla::Milestone::is_active     = \&_milestone_is_active; 
    *Bugzilla::Milestone::is_searchable = \&_milestone_is_searchable; 
}

sub _milestone_is_active {
    return $_[0]->{'is_active'};
}

sub _milestone_is_searchable {
    return $_[0]->{'is_searchable'};
}

sub install_update_db {
    my ($self, $args) = @_;
    my $dbh = Bugzilla->dbh;
    
    # 2008-02-11 rmaia@everythingsolved.com - Bug 274
    $dbh->bz_add_column('milestones', 'is_active',
                        {TYPE => 'BOOLEAN', NOTNULL => 1, DEFAULT => 'TRUE'});

    $dbh->bz_add_column('milestones', 'is_searchable',
                        {TYPE => 'BOOLEAN', NOTNULL => 1, DEFAULT => 'TRUE'});
}

sub object_columns {
    my ($self, $args) = @_;
    my $class = $args->{'class'};
    my $columns = $args->{'columns'};
    
    if ($class->isa('Bugzilla::Milestone')) {
        push(@$columns, "is_active", "is_searchable");
    }
}

sub object_update_columns {
    my ($self, $args) = @_;
    my $object = $args->{'object'};
    my $columns = $args->{'columns'};
    
    if ($object->isa('Bugzilla::Milestone')) {
        push(@$columns, "is_active", "is_searchable");
    }
}

sub _check_is {
    my ($self, $value, $field) = @_;
    $value = $self->check_boolean($value);
    # XXX If you change the name and isactive at the same time,
    # you might be able to bypass this check.
    if (!$value && $self->product->default_milestone eq $self->name) {
        ThrowUserError('milestone_is_default', { milestone => $self });
    }
    
    return $value;
}

sub object_validators {
    my ($self, $args) = @_;
    my $class = $args->{'class'};
    my $validators = $args->{'validators'};
    
    if ($class->isa('Bugzilla::Milestone')) {
        $validators->{'is_active'} = sub { 
            $_[0]->_check_is($_[1], 'is_active');
        };
        
        $validators->{'is_searchable'} = sub { 
            $_[0]->_check_is($_[1], 'is_searchable');
        }
    }
}

# Purpose: link up various Mozilla-specific strings.
sub _link_uuid {
    my $args = shift;
    my $match = html_quote($args->{matches}->[1]);
    
    return qq{<a href="http://crash-stats.mozilla.com/report/index/$match">bp-$match</a>};
}

sub _link_cve {
    my $args = shift;
    my $match = html_quote($args->{matches}->[1]);
    
    return qq{<a href="http://cve.mitre.org/cgi-bin/cvename.cgi?name=$match">$match</a>};
}

sub _link_svn {
    my $args = shift;
    my $match = html_quote($args->{matches}->[1]);
    
    return qq{<a href="http://viewvc.svn.mozilla.org/vc?view=rev&amp;revision=$match">r$match</a>};
}

sub bug_format_comment {
    my ($self, $args) = @_;
    my $regexes = $args->{'regexes'};
  
    push (@$regexes, {
        match => qr/\b(?:UUID\s+|bp\-)([a-f0-9]{8}\-[a-f0-9]{4}\-[a-f0-9]{4}\-
                                       [a-f0-9]{4}\-[a-f0-9]{12})\b/x,
        replace => \&_link_uuid
    });

    push (@$regexes, {
        match => qr/\b((?:CVE|CAN)-\d{4}-\d{4})\b/,
        replace => \&_link_cve
    });

    push (@$regexes, {
        match => qr/\br(\d{4,})\b/,
        replace => \&_link_svn
    });
}

# Purpose: add JSON filter for JSON templates
sub template_before_create {
    my ($self, $args) = @_;
    my $config = $args->{'config'};
    
    $config->{'FILTERS'}->{'json'} = sub {
        my ($var) = @_;
        $var =~ s/([\\\"\/])/\\$1/g;
        $var =~ s/\n/\\n/g;
        $var =~ s/\r/\\r/g;
        $var =~ s/\f/\\f/g;
        $var =~ s/\t/\\t/g;
        return $var;
    };
}

# Purpose: make it always possible to file bugs in certain groups.
sub bug_check_groups {
    my ($self, $args) = @_;
    my $group_names = $args->{'group_names'};
    my $add_groups = $args->{'add_groups'};
    
    foreach my $name (@$group_names) {
        if ($always_fileable_group{$name}) {
            my $group = new Bugzilla::Group({ name => $name }) or next;
            $add_groups->{$group->id} = $group;
        }
    }
}

# Purpose: generically handle generating pretty blocking/status "flags" from
# custom field names.
sub quicksearch_map {
    my ($self, $args) = @_;
    my $full_map = $args->{'full_map'};
    
    foreach my $name (keys %$full_map) {
        if ($name =~ /^cf_(blocking|status)_([a-z]+)?(\d+)?$/) {
            my $type = $1;
            my $product = $2;
            my $version = $3;

            if ($version) {
                $version = join('.', split(//, $version));
            }

            my $pretty_name = $type;
            if ($product) {              
                $pretty_name .= "-" . $product;
            }
            if ($version) {
                $pretty_name .= $version;
            }

            $full_map->{$pretty_name} = $name;
        }
    }
}

# 2006-12-14 justdave@mozilla.com -- Bug 322327
# Add a setting for the product chooser
sub install_before_final_checks {
    my ($self, $args) = @_;
    
    add_setting('product_chooser', 
                ['pretty_product_chooser', 'full_product_chooser'].
                'pretty_product_chooser');
}

__PACKAGE__->NAME;