package Raisin::Param;

use strict;
use warnings;

use Carp;
use Plack::Util::Accessor qw(
    named
    required

    default
    has_default
    desc
    enclosed
    name
    regex
    type
    coerce
);

use Raisin::Util;

my @ATTRIBUTES = qw(name type default regex desc coerce);
my @LOCATIONS = qw(path formData body header query);

sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;

    $self->{named} = $args{named} || 0;
    $self->{required} = $args{type} =~ /^require(s|d)$/ ? 1 : 0;

    return unless $self->_parse($args{spec});

    $self;
}

sub _parse {
    my ($self, $spec) = @_;

    my $has_default = exists $spec->{default} ? 1 : 0;
    $self->{$_} = $spec->{$_} for @ATTRIBUTES;
    $self->{has_default} = $has_default;

    if ($spec->{in}) {
        return unless $self->in($spec->{in});
    }

    if ($spec->{encloses}) {
        if ($self->type->name eq 'HashRef') {
            $self->{enclosed} = _compile_enclosed($spec->{encloses});
        }
        else {
            Raisin::log(
                warn => 'Ignoring enclosed parameters for `%s`, type should be `HashRef` not `%s`',
                $self->name, $self->type->name
            );
        }
    }

    $self->{coerce} = defined($spec->{coerce}) ? $spec->{coerce} : 1;

    return 1;
}

sub _compile_enclosed {
    my $params = shift;

    my @enclosed;
    my $next_param = Raisin::Util::iterate_params($params);
    while (my ($type, $spec) = $next_param->()) {
        last unless $type;

        push @enclosed, Raisin::Param->new(
            named => 0,
            type => $type, # -> requires/optional
            spec => $spec, # -> { name => ..., type => ... }
        );
    }

    \@enclosed;
}

sub display_name { shift->name }

sub in {
    my ($self, $value) = @_;

    if (defined $value) {
        unless (grep { $value eq $_ } @LOCATIONS) {
            Raisin::log(warn => '`%s` should be one of: %s',
                $self->name, join ', ', @LOCATIONS);
            return;
        }

        $self->{in} = $value;
    }

    $self->{in};
}

sub validate {
    my $self = shift;
    my %args = @_ && ref($_[0]) ? (
            ref_value => $_[0],
            quiet     => $_[1],
        ) : @_;
    my $quiet = $args{quiet};

    if (! exists $args{ref_value}) { # no value provided
        # Required and empty
        # Only optional parameters can have default value
        if ($self->required) {
            Raisin::log(warn => '`%s` is required', $self->name) unless $quiet;
            return;
        }
        else {
            Raisin::log(info => '`%s` optional and empty', $self->name);
            return 1;
        }
    }

    # here we got a real ref_value
    my $ref_value = $args{ref_value};

    # Type check
    eval {
        if ($self->type->has_coercion && $self->coerce) {
            $$ref_value = $self->type->coerce($$ref_value);
        }

        if ($self->type->isa('Moose::Meta::TypeConstraint')) {
            $self->type->assert_valid($$ref_value);
        }
        else {
            $$ref_value = $self->type->($$ref_value);
        }
    };
    if (my $e = $@) {
        unless ($quiet) {
            Raisin::log(warn => 'Param `%s` didn\'t pass constraint `%s` with value "%s"',
                $self->name, $self->type->name, $$ref_value);
        }
        return;
    }

    # Nested
    if ($self->type->name eq 'HashRef' && $self->enclosed) {
        for my $p (@{ $self->enclosed }) {
            my $v = $$ref_value;
            my %v = (ref_value => \$v);

            if ($self->type->name eq 'HashRef') {
                if (exists $v->{ $p->name }) {
                    $v = $v->{ $p->name };
                }
                else { # nothing to validate
                    %v = ();
                }
            }

            return unless $p->validate(%v, quiet => $quiet);
        }
    }
    # Regex
    elsif ($self->regex && $$ref_value !~ $self->regex) {
        unless ($quiet) {
            Raisin::log(warn => 'Param `%s` didn\'t match regex `%s` with value "%s"',
                $self->name, $self->regex, $$ref_value);
        }
        return;
    }

    1;
}

1;

__END__

=head1 NAME

Raisin::Param - Parameter class for Raisin.

=head1 DESCRIPTION

Parameter class for L<Raisin>. Validates request paramters.

=head3 coerce

Returns coerce flag. If C<true> attempt to coerce a value will be made at validate stage.

By default set to C<true>.

=head3 default

Returns default value if exists or C<undef>.

=head3 desc

Returns parameter description.

=head3 name

Returns parameter name.

=head3 display_name

An alias to L<Raisin::Param/name>.

=head3 named

Returns C<true> if it's path parameter.

=head3 regex

Return paramter regex if exists or C<undef>.

=head3 required { shift->{required} }

Returns C<true> if it's required parameter.

=head3 type

Returns parameter type object.

=head3 in

Returns the location of the parameter: B<query, header, path, formData, body>.

=head3 validate

Process and validate parameter. Can be invoked as follows:

    $p->validate(\$value);
    $p->validate(\$value, $quiet);
    $p->validate(%args);

In the first and second cases, the first parameter is a reference to the value
to be validated. In this case, it is always assumed that the value was indeed
present and the reference points to its value.

In the second case, parameter C<$quiet> sets the quiet mode, i.e. nothing is
printed on standard error even in case of warnings.

The third case supports following keys:

=over

=item C<ref_value>

a reference to the value, much like C<\$value> above. Its I<absence> means
that the value was not present

=item C<quiet>

a boolean value like C<$quiet> above.

=back

This is the only invocation style that allows you to distinguish between
an absent parameter and an C<undef>ined one.


=head1 AUTHOR

Artur Khabibullin - rtkh E<lt>atE<gt> cpan.org

=head1 LICENSE

This module and all the modules in this package are governed by the same license
as Perl itself.

=cut
