package Finance::Bank::DE::DeutscheBank;

use strict;
use warnings;
use Carp;
use base 'Class::Accessor';

use WWW::Mechanize;
use HTML::LinkExtractor;
use HTML::TreeBuilder;

use vars qw[ $VERSION ];

$VERSION = '0.01';

BEGIN	{
		Finance::Bank::DE::DeutscheBank->mk_accessors(qw( agent ));
	};

use constant BASEURL	=> 'https://meine.deutsche-bank.de';
use constant LOGIN	=> BASEURL . '/mod/WebObjects/dbpbc.woa';
use constant FUNCTIONS	=> "(Daueraufträge)|(Direkteinstieg)|(Ihr Konto)|(Inlands-Überweisung)|(Kontakt & Service)|(Kontoübersicht)|(Sicherheit)|(Überweisungsvorlagen)";

sub new
{
	my ($class,%args) = @_;

	croak "Filiale/Branch number must be specified"
		unless $args{Branch};

	croak "Konto/Account number must be specified"
		unless $args{Account};

	croak "Unterkonto/SubAccount number must be specified"
		unless $args{SubAccount};

	croak "PIN/Password must be specified"
		unless $args{PIN};

	my $logger = $args{status} || sub {};

	my $self = {
			agent		=> undef,
			account		=> $args{Account},
			password	=> $args{PIN},
			branch		=> $args{Branch},
			subaccount	=> $args{SubAccount},
			logger		=> $logger,
			navigation	=> undef,
		};
	bless $self, $class;

	$self->log("New $class created");
	$self;
};


sub log
{
	$_[0]->{logger}->(@_);
};


sub log_httpresult
{
	$_[0]->log("HTTP Code",$_[0]->agent->status,$_[0]->agent->res->as_string)
};


sub new_session
{
	# Reset our user agent
	my ($self) = @_;
	my $url;

	$self->close_session()
		if ($self->agent);

	my $result = $self->get_login_page(LOGIN);

	if ( $result != 200 )
	{
		$self->log("Status","Banking is unavailable");
		die "Banking is unavailable";
	}

	if ( $result == 200 )
	{
		if ($self->maintenance)
		{
			$self->log("Status","Banking is unavailable due to maintenance");
			die "Banking unavailable due to maintenance";
		};

		my $agent = $self->agent();
		my $function = 'ACCOUNTBALANCE';
		$self->log("Logging into function $function");

		$agent->current_form->value('AccountNumber',$self->{account});
		$agent->current_form->value('Branch',$self->{branch});
		$agent->current_form->value('SubAccount',$self->{subaccount});
		$agent->current_form->value('PIN',$self->{password});

		$^W=0;
		$agent->current_form->value('appName', 'Netscape');
		$agent->current_form->value('appVersion', '4.78 (Linux 2.4.19-4GB i686; U)');
		$agent->current_form->value('platform', 'Linux');

		# VALIDATION_TRIGGER_1 is used to trigger 'LOGIN'
		$result = $agent->click('VALIDATION_TRIGGER_1', 27, 7 );

		# get navigator frame ( extract link )
		my $navigator = $agent->find_link( 'name' => 'navigator' );

		# first we have to get the content frame ! other way around won't work !!
		$agent->follow_link( 'name' => 'content' );

		# then we can get navigator frame content
		$agent->get( BASEURL . $navigator->[0] );
		$^W=1;

		# extract links to account functions
		my $LinkExtractor = new HTML::LinkExtractor();
		$LinkExtractor->strip( 1 );
		$LinkExtractor->parse(\$agent->content());

		# now we have the links in the format
		#	{
		#		'_TEXT' => 'Kontoübersicht',
		#		'target' => '_top',
		#		'href' => '/mod/WebObjects/dbpbc.woa/618/wo/HpRl1hqezkxfYRosJRjTg0/4.11.1.5.3.3.5.3',
		#		'tag' => 'a',
		#		'class' => 'NaviDirektLink'
		#	},
		#	{	...
		#	}
		#


		# but I would like to have them as
		# 	{
		# 		'_TEXT' => 'Kontoübersicht',
		# 		'href' => '/mod/WebObjects/dbpbc.woa/618/wo/HpRl1hqezkxfYRosJRjTg0/4.11.1.5.3.3.5.3',
		# 	},
		# 	{	...
		#	}
		# and only for supported functions ( not all links and images ... )

		my @tmp = ();
		foreach my $elem ( @{$LinkExtractor->links} )
		{
			if (( defined( $elem->{ '_TEXT' } ) && ( $elem->{ '_TEXT' } ne '' ) && ( $elem->{ '_TEXT' } =~ "m/". FUNCTIONS ."/" )) )
			{
				foreach $_ ( keys %$elem )
				{
					if ( $_ !~ m/(_TEXT)|(href)/ )
					{
						delete $elem->{ $_ };
					}
				}

				push @tmp, \%$elem;
			}
		}

		$self->{navigation} = \@tmp;
		$self->log_httpresult();
		$result = $agent->status;
	};
	$result;
};


sub get_login_page
{
	my ($self,$url) = @_;
	$self->log("Connecting to $url");
	$self->agent(WWW::Mechanize->new(agent => "Mozilla/4.78 (Linux 2.4.19-4GB i686; U) Opera 6.03 [en]"));

	my $agent = $self->agent();
	$agent->get(LOGIN);
	$self->log_httpresult();
	$agent->status;
};


sub error_page {
  # Check if an error page is shown (a page with much red on it)
  my ($self) = @_;
  $self->agent->content =~ /<tr valign="top" bgcolor="#FF0033">/sm;
};

sub maintenance
{
	my ($self) = @_;
	$self->error_page and
	$self->agent->content =~ /derzeit steht das Internet Banking aufgrund von Wartungsarbeiten leider nicht zur Verf&uuml;gung.\s*<br>\s*In K&uuml;rze wird das Internet Banking wieder wie gewohnt erreichbar sein./gsm;
};

sub access_denied {
  my ($self) = @_;
  my $content = $self->agent->content;

  $self->error_page and
  (  $content =~ /Die eingegebene Kontonummer ist unvollst&auml;ndig oder falsch\..*\(2051\)/gsm
  or $content =~ /Die eingegebene PIN ist falsch\. Bitte geben Sie die richtige PIN ein\.\s*\(10011\)/gsm
  or $content =~ /Die von Ihnen eingegebene Kontonummer ist ung&uuml;ltig und entspricht keiner Deutsche Bank-Kontonummer.\s*\(3040\)/gsm );
};

sub session_timed_out {
  my ($self) = @_;
  $self->agent->content =~ /Die Sitzungsdaten sind ung&uuml;ltig, bitte f&uuml;hren Sie einen erneuten Login durch.\s+\(27000\)/;
};

sub functions
{
	my ($self,$function) = @_;
	my $link = ();

    	if ( $function =~ "m/". FUNCTIONS ."/" )
	{
		foreach $_ ( @{$self->{ navigation }} )
		{
			if ( $_->{ '_TEXT' } eq $function )
			{
				$link = $_->{ 'href' };
			}
		}
		return $link;
	}
	else
	{
		return 0;
	}
}

sub select_function
{
	my ($self,$function) = @_;
	carp "Unknown account function '$function'"
		unless $self->functions($function);

	$self->new_session unless $self->agent;

	$self->agent->get( $self->functions( "$function" ) );
	if ( $self->session_timed_out )
	{
		$self->log("Session timed out");
		$self->agent(undef);
		$self->new_session();
		$self->agent->get( $self->functions( $function ) );
	};
	$self->log_httpresult();
	$self->agent->status;
};

sub close_session
{
	my ($self) = @_;
	my $result;
	if (not $self->access_denied)
	{
		$self->log("Closing session");
		$self->select_function('quit');
		$result = $self->agent->res->as_string =~ /Online-Banking\s+beendet/sm;
	}
	else
	{
		$result = 'Never logged in';
	};
	$self->agent(undef);
	$result;
};


sub login
{
	my ($self) = @_;

	$self->new_session();

	my $agent = $self->agent();

	if ( $agent->status == 200 )
	{
		return 1;
	}
	else
	{
		return 0;
	};
};


sub parse_account_overview
{
	my ($self) = @_;
	my $agent = $self->agent();
	my @saldo = ();
	my $count = 0;

	my $tree = HTML::TreeBuilder->new();
	$tree->parse( $agent->content() );

	my @Entries =();
	foreach my $row ( $tree->find_by_tag_name('tr') )
	{
		$count += 1;
		@Entries =();
		foreach my $child ( $row->content_list() )
		{
			if ( ref $child and $child->tag eq 'td' )
			{
				my $tmp = $child->as_text;
				$tmp =~ s/^[ 	]*//g;
				$tmp =~ s/[ 	]*$//g;
				$tmp =~ s/\240//g;
				push( @Entries, ( $tmp ) );
			}
		}
		if (( $count == 4 ) || ( $count == 5) )
		{
			push( @saldo, @Entries );
		}
	}

	$count = @saldo;

	my %saldo = ();
	for ( my $i = 1; $i <= ($count/2); $i++ )
	{
		$saldo{ $saldo[ $i - 1 ] } = $saldo[ $count/2-1 + $i ];
	}
	return %saldo
}


sub saldo
{
	my ($self) = @_;

	my $agent = $self->agent;
	if ($agent)
	{
		$^W=0;
		$self->select_function('Kontoübersicht');
		$agent->follow_link( 'name' => 'content' );
		$^W=1;

		return $self->parse_account_overview();
	}
	else
	{
		return undef;
	}
};

sub account_statement
{
	my ($self, %parameter) = @_;

	my $count = 0;
	my @header = ();
	my @Entries = ();
	my @AccountStatement = ();
	my $AccountRow = ();

	my @date;
	my $agent = $self->agent;
	if ($agent)
	{
		$^W=0;
		$self->select_function('Kontoübersicht');
		$agent->follow_link( 'name' => 'content' );

		my %account = $self->parse_account_overview();
		$agent->follow_link( 'text' => $account{ 'Bezeichnung' } );
		$^W=1;

		my $tree = HTML::TreeBuilder->new();

		$tree->parse( $agent->content );

		foreach my $inputelem ( $tree->look_down('_tag', 'input') )
		{
			if ( $inputelem->attr('type') eq 'text' )
			{
				# text elem 1 - 6 are needed to enter from/till date
				push @date, $inputelem->attr('name');
			}
		}

		my $sort = ();
		foreach my $selectelem ( $tree->look_down('_tag', 'select') )
		{
			$sort = $selectelem->attr('name');
		}

		# should I get account statement for user defined period ?
		if ( defined $parameter{ 'period' } )
		{
			my ( $day, $month, $year ) = split( '\.', $parameter{ 'StartDate' } );

			$day	= sprintf("%02d", $day );
			$month	= sprintf("%02d", $month );
			$year	= sprintf("%04d", $year );

			croak "Year must have 4 digits in StartDate"
				unless ( length $year == 4 );

			$agent->current_form->value('time','period');
			$agent->current_form->value( $date[0], $day );
			$agent->current_form->value( $date[1], $month );
			$agent->current_form->value( $date[2], $year );

			( $day, $month, $year ) = split( '\.', $parameter{ 'EndDate' } );
			$day	= sprintf("%02d", $day );
			$month	= sprintf("%02d", $month );
			$year	= sprintf("%04d", $year );

			croak "Year must have 4 digits in EndDate"
				unless ( length $year == 4 );

			$agent->current_form->value('time','period');
			$agent->current_form->value( $date[3], $day );
			$agent->current_form->value( $date[4], $month );
			$agent->current_form->value( $date[5], $year );
		}
		else
		{
			# this is the default ( statements since last login
			$agent->current_form->value('time','lastLogin');
		}

		$^W=0;
		# VALIDATION_TRIGGER_1 is used to trigger 'LOGIN'
		my $result = $agent->click('VALIDATION_TRIGGER1' );

		# first we have to get the content frame ! other way around won't work !!
		$agent->follow_link( 'name' => 'content' );
		$^W=1;

		$tree = HTML::TreeBuilder->new();
		$tree->parse( $agent->content() );

		foreach my $table ( $tree->look_down('_tag', 'table') )
		{
			foreach my $row ( $table->look_down('_tag', 'tr') )
			{
				@Entries =();
				foreach my $child ( $row->look_down('_tag', 'td') )
				{
					if (( defined $child->attr('class')) && ( $child->attr('class') eq 'tablehead' ))
					{
						my $tmp = $child->as_trimmed_text;
						$tmp =~ s/^[ 	]*//g;
						$tmp =~ s/[ 	]*$//g;
						$tmp =~ s/\240//g;
						push( @header, ( $tmp ) );
						$count += 1;
					}
					elsif ( $child->as_trimmed_text =~ 'Kontostand' )
					{
						$count = 0;
					}
					elsif ( $count >= 6 )
					{
						$count += 1;
						$AccountRow = ($count -1)/ 6;
						$AccountRow = sprintf( "%d", $AccountRow );

						my $tmp = $child->as_trimmed_text;
						$tmp =~ s/^[ 	]*//g;
						$tmp =~ s/[ 	]*$//g;
						$tmp =~ s/\240//g;
						$AccountStatement[ $AccountRow - 1 ]{ $header[ ($count - 1) % 6 ] } = $tmp;
					}

				}
			}
		}
		return @AccountStatement;
	}
	else
	{
		return undef;
	}
}


sub transfer
{
	my ($self, %parameter) = @_;

	my $count = 0;
	my @header = ();
	my @Entries = ();
	my @AccountStatement = ();
	my $AccountRow = ();

	my $agent = $self->agent;
	if ($agent)
	{
		$^W=0;
		$self->select_function('Inlands-Überweisung');
		$agent->follow_link( 'name' => 'content' );
		$^W=1;

		croak "Receiver name must be defined"
			unless ( defined $parameter{ 'Receiver' } );

		croak "Receiver name must not exceed 27 digits"
			unless (( length $parameter{ 'Receiver' } <= 27 )&&( length $parameter{ 'Receiver' } >= 1 ));

		croak "Receiver account number must be defined"
			unless ( defined $parameter{ 'RecAccount' } );

		croak "Receiver account number must not exceed 10 digits"
			unless (( length $parameter{ 'RecAccount' } <= 10 )&&( length $parameter{ 'RecAccount' } >= 1 ));

		croak "Receiver bank number (BLZ) must be defined"
			unless ( defined $parameter{ 'RecBLZ' } );

		croak "Receiver bank number (BLZ) must not exceed 10 digits"
			unless (( length $parameter{ 'RecBLZ' } <= 10 )&&( length $parameter{ 'RecBLZ' } >= 1 ));

		croak "Transfer amount must be defined"
			unless ( defined $parameter{ 'Amount' } );

		croak "Transfer amount must not exceed 14 digits"
			unless (( length $parameter{ 'Amount' } <= 14 )&&( length $parameter{ 'Amount' } >= 1 ));

		croak "Usage1 (Vermerk) must be defined"
			unless ( defined $parameter{ 'Usage1' } );

		croak "Usage1 (Vermerk) must not exceed 27 characters"
			unless (( length $parameter{ 'Usage1' } <= 27 )&&( length $parameter{ 'Usage1' } >= 1 ));

		$parameter{ 'Usage2' } = $parameter{ 'Usage2' } || "";
		$parameter{ 'Usage3' } = $parameter{ 'Usage3' } || "";
		$parameter{ 'Usage4' } = $parameter{ 'Usage4' } || "";

		croak "Usage2 (Vermerk) must not exceed 27 characters"
			unless ( length $parameter{ 'Usage2' } <= 27 );

		croak "Usage3 (Vermerk) must not exceed 27 characters"
			unless ( length $parameter{ 'Usage3' } <= 27 );

		croak "Usage4 (Vermerk) must not exceed 27 characters"
			unless ( length $parameter{ 'Usage4' } <= 27 );


		$agent->current_form->value('Receiver',		$parameter{ 'Receiver' });
		$agent->current_form->value('RecAccount',	$parameter{ 'RecAccount' });
		$agent->current_form->value('RecBLZ',		$parameter{ 'RecBLZ' });
		$agent->current_form->value('Amount',		$parameter{ 'Amount' });
		$agent->current_form->value('Usage1',		$parameter{ 'Usage1' });
		$agent->current_form->value('Usage2',		$parameter{ 'Usage2' });
		$agent->current_form->value('Usage3',		$parameter{ 'Usage3' });
		$agent->current_form->value('Usage4',		$parameter{ 'Usage4' });

		$^W=0;
		# VALIDATION_TRIGGER is used to trigger 'transfer'
		my $result = $agent->click('VALIDATION_TRIGGER' );

		# first we have to get the content frame ! other way around won't work !!
		$agent->follow_link( 'name' => 'content' );
		$^W=1;

		croak "Tan must be defined"
			unless ( defined $parameter{ 'Tan' } );

		croak "Tan must have 6 digits"
			unless ( length $parameter{ 'Tan' } == 6 );

		$agent->current_form->value('Tan',		$parameter{ 'Tan' });

		$^W=0;
		# VALIDATION_TRIGGER is used to trigger 'transfer'
		$result = $agent->click('VALIDATION_TRIGGER' );

		# first we have to get the content frame ! other way around won't work !!
		$agent->follow_link( 'name' => 'content' );
		$^W=1;

		return 1;
	}
	else
	{
		return undef;
	}
}

1;
__END__

=head1 NAME

Finance::Bank::DE::DeutscheBank - Checks your Deutsche Bank account from Perl

=head1 SYNOPSIS

=for example begin

  use strict;
  use Finance::Bank::DE::DeutscheBank;
  my $account = Finance::Bank::DE::DeutscheBank->new(
		Branch		=> '600',
		Account		=> '1234567',
		SubAccount	=> '00',
		PIN		=> '543210',

                status => sub { shift;
                                print join(" ", @_),"\n"
                                  if ($_[0] eq "HTTP Code")
                                      and ($_[1] != 200)
                                  or ($_[0] ne "HTTP Code");

                              },
              );
  # login to account
  if ( $account->login() )
  {
	print( "successfully logged into account\n" );
  }
  else
  {
	print( "error, can not log into account\n" );
  }

  my %saldo = $account->saldo();
  print("The amount of money you have is: $saldo{ 'Saldo' } $saldo{ 'Währung' }\n");

  # get account statement
  my %parameter = (
                        period => 1,
                        StartDate => "10.10.2003",
                        EndDate => "29.11.2003",
                  );

  my @account_statement = $account->account_statement(%parameter);

  $account->close_session;

=for example end

=head1 DESCRIPTION

This module provides a rudimentary interface to the Deutsche Bank online banking system at
https://meine.deutsche-bank.de/. You will need either Crypt::SSLeay or IO::Socket::SSL
installed for HTTPS support to work with LWP.

The interface was cooked up by me by having a look at some other Finance::Bank
modules. If you have any proposals for a change, they are welcome !

=head1 WARNING

This is code for online banking, and that means your money, and that means BE CAREFUL. You are encouraged, nay, expected, to audit the source of this module yourself to reassure yourself that I am not doing anything untoward with your banking data. This software is useful to me, but is provided under NO GUARANTEE, explicit or implied.

=head1 WARNUNG

Dieser Code beschaeftigt sich mit Online Banking, das heisst, hier geht es um Dein Geld und das bedeutet SEI VORSICHTIG ! Ich gehe
davon aus, dass Du den Quellcode persoenlich anschaust, um Dich zu vergewissern, dass ich nichts unrechtes mit Deinen Bankdaten
anfange. Diese Software finde ich persoenlich nuetzlich, aber ich stelle sie OHNE JEDE GARANTIE zur Verfuegung, weder eine
ausdrueckliche noch eine implizierte Garantie.

=head1 METHODS

=head2 new( %parameter )

Creates a new object. It takes four named parameters :

=over 5

=item Branch => '600'

The Branch/Geschaeftstelle which is responsible for you.

=item Account => '1234567'

This is your account number.

=item SubAccount => '00'

This is your subaccount number.

=item PIN => '11111'

This is your PIN.

=item status => sub {}

This is an optional
parameter where you can specify a callback that will receive the messages the object
Finance::Bank::DE::DeutscheBank produces per session.

=back

=head2 login()

Closes the current session and logs in to the website using
the credentials given at construction time.

=head2 close_session()

Closes the session and invalidates it on the server.

=head2 agent()

Returns the C<WWW::Mechanize> object. You can retrieve the
content of the current page from there.

=head2 select_function( STRING )

Selects a function. The three currently supported functions are C<Inlands-Überweisung>, C<Kontoübersicht> and C<quit>.
Which means transfer, account statement and quit.

=head2 account_statement( %parameter )

Navigates to the html page which contains the account statement. The content is retrieved
by the agent, parsed by parse_account_overview and returned as an array of hashes.
Like:
@VAR =( {
          'Buchungstag' => '18.11.2003',
          'Wert' => '18.11.2003',
          'Verwendungszweck' => 'this is for you',
          'Haben' => '40,00',
          'Soll' => '',
          'Währung' => 'EUR'
        },
        {
          'Buchungstag' => '19.11.2003',
          'Wert' => '19.11.2003',
          'Verwendungszweck' => 'this was mine',
          'Haben'  => '',
          'Soll' => '-123.98',
          'Währung' => 'EUR'
        }) ;

Keys are in german because they are retrieved directly from the header of the
HTML tables.

You can pass a hash to this method to tell the period you would like to
get the statement for. If you don't pass a parameter then you'll receive
the account statement since your last visit at the Banks server.
Parameter to pass to the function:

my %parameter = (
                        period => 1,
                        StartDate => "10.10.2003",
                        EndDate => "29.11.2003",
                );

If period is set to 1 then StartDate and EndDate will be used otherwise
since last login at the banks server is used. StartDate and EndDate have to
be in german format.

=head2 transfer( %parameter )

This method transfers money to the specified account passed to the function.

%parameter =    (
                        Receiver        => 'Wolfgang Schlüschen',
                        RecAccount      => '1234567890',
                        RecBLZ          => '20080000',
                        Amount          => '1,00',
                        Usage1          => 'Programming',
                        Tan             => '123456',
                );
$account->transfer( %parameter );

It is possible to use up to 4 lines for Usage ( Usage[1-4] ). The length 
in all fields is restricted and checked by the function.

=head1 TODO:

  * Add runtime tests to validate the HTML resp. responses from the server

=head1 SEE ALSO

L<perl>, L<WWW::Mechanize>.

=head1 AUTHOR

Wolfgang Schlueschen, E<lt>wschl@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003 by Wolfgang Schlueschen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
