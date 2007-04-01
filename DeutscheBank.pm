package Finance::Bank::DE::DeutscheBank;
use strict;
use warnings;
use Carp;
use base 'Class::Accessor';

use WWW::Mechanize;
use HTML::LinkExtractor;
use HTML::TreeBuilder;
use Text::CSV_XS;

use vars qw[ $VERSION ];

$VERSION = '0.04';

BEGIN	{
		Finance::Bank::DE::DeutscheBank->mk_accessors(qw( agent ));
	};

use constant BASEURL	=> 'https://meine.deutsche-bank.de';
use constant LOGIN	=> BASEURL . '/mod/WebObjects/dbpbc.woa';
use constant FUNCTIONS	=> "(Übersicht)|(Ihr Konto)|(Ihr Depot)|(Service / Optionen)|(Umsatzanzeige)|(Inlands-Überweisung)|(Daueraufträge)|(Lastschrift)|(Kunden-Logout)|(Überweisungsvorlagen)(Ihre Finanzübersicht als PDF-Datei speichern)|(Ihre Finanzübersicht als CSV-Datei speichern)";

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
		$self->log("Status"," Banking is unavailable");
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

		local $^W=0;
		$agent->current_form->value('appName', 'Netscape');
		$agent->current_form->value('appVersion', '4.78 (Linux 2.4.19-4GB i686; U)');
		$agent->current_form->value('platform', 'Linux');

		# VALIDATION_TRIGGER_1 is used to trigger 'LOGIN'
		$result = $agent->click('VALIDATION_TRIGGER_1' );

		if ( $self->access_denied )
		{
			$self->log("Not possible to authenticate at bank server ( wrong account/pin combination ? )");
			return 0;
		}

		# extract links to account functions
		my $LinkExtractor = new HTML::LinkExtractor();

		$LinkExtractor->strip( 1 );
		$LinkExtractor->parse(\$agent->content());

		# needed here because of empty links ( href attribute )
		local $^W=1;

		# now we have the links in the format
		#	{
		#		'_TEXT' => 'Übersicht',
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
		# 		'_TEXT' => 'Übersicht',
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

				# get all but broken links
				if ( $elem->{ '_TEXT' } !~ m/Ihre Finanzübersicht als [CP][SD][VF]-Datei speichern/ )
				{
					push @tmp, \%$elem;
				}
			}
		}

		# get links for additional functions / broken links ( onclick )
		my $navigator =  $agent->find_link( text_regex => qr/Ihre Finanzübersicht als PDF-Datei speichern/ );
		push @tmp, {	'_TEXT'	=> 'Ihre Finanzübersicht als PDF-Datei speichern',
				'href'	=> $navigator->[5]{ 'onclick' }
			   };

		$navigator =  $agent->find_link( text_regex => qr/Ihre Finanzübersicht als CSV-Datei speichern/ );
		push @tmp, {	'_TEXT'	=> 'Ihre Finanzübersicht als CSV-Datei speichern',
				'href'	=> $navigator->[5]{ 'onclick' }
			   };

		# save these links so that we can remember them
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
  $self->agent->content =~ /<tr valign="top" bgcolor="#FF0033">/sm || $self->agent->content =~ /<div class="errorMsg">/ || $self->agent->content =~ /<div class="backendErrorMsg">/ ;
};

sub maintenance
{
	my ($self) = @_;
	$self->error_page or
	$self->agent->content =~ /derzeit steht das Internet Banking aufgrund von Wartungsarbeiten leider nicht zur Verf&uuml;gung.\s*<br>\s*In K&uuml;rze wird das Internet Banking wieder wie gewohnt erreichbar sein./gsm;
};

sub access_denied {
  my ($self) = @_;
  my $content = $self->agent->content;

  $self->error_page or
  (  $content =~ /Die eingegebene Kontonummer ist unvollst&auml;ndig oder falsch\..*\(2051\)/gsm
  or $content =~ /Die eingegebene PIN ist falsch\. Bitte geben Sie die richtige PIN ein\.\s*\(10011\)/gsm
  or $content =~ /Die von Ihnen eingegebene Kontonummer ist ung&uuml;ltig und entspricht keiner Deutsche Bank-Kontonummer.\s*\(3040\)/gsm
  or $content =~ /Leider konnte Ihre Anmeldung nicht erfolgreich durchgef&uuml;hrt werden/
  or $content =~ /Bitte geben Sie ein g&uuml;ltiges Datum ein/ );
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
		local $^W=0;
		$self->select_function('Kunden-Logout');
		local $^W=1;
		$result = $self->agent->res->as_string =~ /https:\/\/wob.deutsche-bank.de\/trxm\/logout\/pbc\/logout_pbc.html/;
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

	if ( $self->new_session() )
	{
		return 1;
	}
	else
	{
		return 0; 
	}

};


sub parse_account_overview
{
	my ($self) = @_;
	my $agent = $self->agent();
	my %saldo = ();

	my $tree = HTML::TreeBuilder->new();
	$tree->parse( $agent->content() );

	foreach my $table ( $tree->look_down('_tag', 'table') )
	{
		foreach my $row ( $table->look_down('_tag', 'tr') )
		{
			foreach my $child ( $row->look_down('_tag', 'td') )
			{
				if (( defined $child->attr('class')) && (( $child->attr('class') eq 'total balance')||($child->attr('class') eq 'total currency')))
				{
					my $tmp = $child->as_trimmed_text;

					if ( $child->attr('class') eq 'total balance')
					{
						$saldo{ 'Saldo' }  = $tmp;
					}
					elsif ($child->attr('class') eq 'total currency')
					{
						$saldo{ 'Währung' } = $tmp;
					}
				}
			}
		}
	} 

	return %saldo
}


sub saldo
{
	my ($self) = @_;

	my $agent = $self->agent;
	if ($agent)
	{
		local $^W=0;
		$self->select_function('Übersicht');
		local $^W=1;

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
	my @AccountStatement = ();
	my $AccountRow = ();
	my @date;
	my $agent = $self->agent;
	if ($agent)
	{
		local $^W=0;
		$self->select_function('Übersicht');

		my %account = $self->parse_account_overview();
		$agent->follow_link( 'text' => 'Umsatzanzeige' );
		local $^W=1;

		my $tree = HTML::TreeBuilder->new();

		$tree->parse( $agent->content );

		my $LinkFixed = ();

		foreach my $selectelem ( $tree->look_down('_tag', 'select') )
		{
			if (( defined $selectelem->attr('onchange') ) && ( $selectelem->attr('onchange') eq 'document.calForm.time[1].click();' ))
			{
				$LinkFixed = $selectelem->attr('name');
			}
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

			$agent->current_form->value( 'time','period');
			$agent->current_form->value( 'fromDatecal_0', $day );
			$agent->current_form->value( 'fromDatecal_1', $month );
			$agent->current_form->value( 'fromDatecal_2', $year );

			( $day, $month, $year ) = split( '\.', $parameter{ 'EndDate' } );
			$day	= sprintf("%02d", $day );
			$month	= sprintf("%02d", $month );
			$year	= sprintf("%04d", $year );

			croak "Year must have 4 digits in EndDate"
				unless ( length $year == 4 );

			$agent->current_form->value( 'time','period');
			$agent->current_form->value( 'toDatecal_0', $day );
			$agent->current_form->value( 'toDatecal_1', $month );
			$agent->current_form->value( 'toDatecal_2', $year );
		}
		elsif ( defined $parameter{ 'last' } )
		{
			my $last = ();
			$agent->current_form->value('time','fixed');
			if ( $parameter{ 'last' } <= 10 )
			{
				$last = 0;
			}
			elsif ( $parameter{ 'last' } <= 20 )
			{
				$last = 1;
			}
			elsif ( $parameter{ 'last' } <= 30 )
			{
				$last = 2;
			}
			elsif ( $parameter{ 'last' } <= 60 )
			{
				$last = 3;
			}
			elsif ( $parameter{ 'last' } <= 90 )
			{
				$last = 4;
			}
			else	# > 90
			{
				$last = 5;
			}
			$agent->current_form->value($LinkFixed, $last);
		}
		else	#expect that per default last login date is set ...
		{
			;
		}

		local $^W=0;
		# VALIDATION_TRIGGER_1 is used to trigger update of account balance
		my $result = $agent->click('VALIDATION_TRIGGER1' ); 

		# VALIDATION_TRIGGER_5 is used to get CSV formated data of account balance
		$result = $agent->click('VALIDATION_TRIGGER_5' ); 
		local $^W=1;

		#successfully downloaded account balance data in csv format
		if ( $result->is_success )
		{
			my @balance = split( '\n', $result->content );
			my $csv = Text::CSV_XS->new( { 'sep_char'    => ';' });

			my $StartLineDetected = 0;
			for ( my $loop = 0; $loop < scalar @balance; $loop++ )
			{
				my $line = $balance[ $loop ];
				chomp( $line );

				if ( $StartLineDetected == 1 )
				{
					my $status = $csv->parse( $line );
					@header = $csv->fields();
					$AccountRow = 0;
					@AccountStatement = ();
					$StartLineDetected = 2;
				}
				elsif ( $StartLineDetected == 2 )
				{
					if ( $line !~ /^Kontostand "/ )
					{
						my $status = $csv->parse( $line );
						my @columns = $csv->fields();

						for (my $loop = 0; $loop < scalar @columns; $loop++ ) 
						{ 
							$AccountStatement[ $AccountRow ]{ $header[ $loop ] } = $columns[ $loop ];
						}
						$AccountRow++; 
					}
				}
				elsif ( $line =~ /Vorgemerkte und noch nicht gebuchte Umsätze sind nicht Bestandteil dieser Aufstellung/ )
				{
					$StartLineDetected = 1;
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
	my %SingleRemittance = ();

	my $agent = $self->agent;
	if ($agent)
	{
		local $^W=0;
		$self->select_function('Inlands-Überweisung');
		local $^W=1;

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

		$parameter{ 'Usage2' } = $parameter{ 'Usage2' } || "";
		$parameter{ 'Usage3' } = $parameter{ 'Usage3' } || "";
		$parameter{ 'Usage4' } = $parameter{ 'Usage4' } || "";

		$parameter{ 'Usage1' } .= " " . $parameter{ 'Usage2' };
		$parameter{ 'Usage1' } .= " " . $parameter{ 'Usage3' };
		$parameter{ 'Usage1' } .= " " . $parameter{ 'Usage4' };

		croak "Usage (Vermerk) must not exceed 108 characters"
			unless (( length $parameter{ 'Usage1' } <= 108 )&&( length $parameter{ 'Usage1' } >= 1 ));
		
		my $tree = HTML::TreeBuilder->new();
		$tree->parse( $agent->content() );
		foreach my $inputelem ( $tree->look_down('_tag', 'input') )
		{
			if (( defined $inputelem->attr('class') ) && ( $inputelem->attr('class') =~ m/(^calDD$)|(^calMM$)|(^calYYYY$)/ ))
			{
				$SingleRemittance{ $inputelem->attr('class') } = $inputelem->attr('name');
			}
		}

		# check if this remittance should be executed on a specific date
		if ( defined $parameter{ 'Date' } )
		{
			my ( $day, $month, $year ) = split( '\.', $parameter{ 'Date' } );
			$day	= sprintf("%02d", $day );
			$month	= sprintf("%02d", $month );
			$year	= sprintf("%04d", $year );

			croak "Year must have 4 digits in Date"
				unless ( length $year == 4 );

			$agent->current_form->value( $SingleRemittance{  'calDD'  }, $day );
			$agent->current_form->value( $SingleRemittance{  'calMM'  }, $month );
			$agent->current_form->value( $SingleRemittance{ 'calYYYY' }, $year );
		}
		else
		{
			# no specific date; do it as soon as possible
			;
		}


		$agent->current_form->value('Receiver',		$parameter{ 'Receiver' });
		$agent->current_form->value('RecAccount',	$parameter{ 'RecAccount' });
		$agent->current_form->value('RecBLZ',		$parameter{ 'RecBLZ' });
		$agent->current_form->value('Amount',		$parameter{ 'Amount' });
		$agent->current_form->value('Usage',		$parameter{ 'Usage1' });

		local $^W=0;
		# VALIDATION_TRIGGER is used to trigger 'transfer'
		my $result = $agent->click('VALIDATION_TRIGGER' ); 
		local $^W=1;

		croak "An error occured during submitting data"
			unless ( ! $self->error_page );

		croak "Tan must be defined"
			unless ( defined $parameter{ 'Tan' } );

		croak "Tan must have 6 digits"
			unless ( length $parameter{ 'Tan' } == 6 );

		$agent->current_form->value('mCk',		$parameter{ 'Tan' });

		local $^W=0;
		# VALIDATION_TRIGGER is used to trigger 'transfer'
		$result = $agent->click('VALIDATION_TRIGGER_1' ); 
		local $^W=1;

		if ( $self->error_page )
		{ 
			carp "an error occured during tan submision";
			return 0;
		}
		else
		{
			return 1;
		}
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
                        StartDate => "01.01.2005",
                        EndDate => "02.02.2005",
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

Selects a function. The three currently supported functions are C<Inlands-Überweisung>, C<Übersicht> and C<Kunden-Logout>.
Which means transfer, account statement and quit.

=head2 account_statement( %parameter )

Navigates to the html page which contains the account statement. The content is retrieved
by the agent, parsed by parse_account_overview and returned as an array of hashes.
Like:
@VAR =( {
          'Buchungstag' => '18.02.2005',
          'Wert' => '18.02.2005',
          'Verwendungszweck' => 'this is for you',
          'Haben' => '40,00',
          'Soll' => '',
          'Waehrung' => 'EUR'
        },
        {
          'Buchungstag' => '19.02.2005',
          'Wert' => '19.02.2003',
          'Verwendungszweck' => 'this was mine',
          'Haben'  => '',
          'Soll' => '-123.98',
          'Waehrung' => 'EUR'
        }) ;

Keys are in german because they are retrieved directly from the header of the
csv file which is downloaded from the server.

You can pass a hash to this method to tell the period you would like to
get the statement for. If you don't pass a parameter then you'll receive
the account statement since your last visit at the Banks server.
Parameter to pass to the function:

my %parameter = (
                        period => 1,
                        StartDate => "10.02.2005",
                        EndDate => "28.02.2005",
                );

If period is set to 1 then StartDate and EndDate will be used.

The second possibilty is to get an account overview for the last n days.

my %parameter = (
                        last => 10,
                );

This will retrieve an overview for the last ten days.
The bank server allows 10,20,30,60,90 days. If you specify any other
value then the method account_statement will use one of the above values
( the next biggest one ).

If neither period nor last is defined last login date at the bank
server is used. StartDate and EndDate have to
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

To be compatible to previous verion it possible to use up to 4 lines for Usage ( Usage[1-4] ).
The banks server only knows about Usage1. The method transfer concatenates Usage[1-4] if
available. The length in all fields is restricted and checked by the function.

=head1 TODO:

  * Allthough more checks have been implemented to validate the HTML resp. responses from the server
it might be that some are still missing. Please let me know your feedback.

=head1 SEE ALSO

L<perl>, L<WWW::Mechanize>.

=head1 AUTHOR

Wolfgang Schlueschen, E<lt>wschl@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003, 2004, 2005, 2006, 2007 by Wolfgang Schlueschen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
