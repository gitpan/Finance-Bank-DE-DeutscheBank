use 5.005;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'Finance::Bank::DE::DeutscheBank',
    'VERSION_FROM'	=> 'DeutscheBank.pm', # finds $VERSION
    'PREREQ_PM'		=> {
				'WWW::Mechanize' => 0.35,
				'HTML::TreeBuilder' => undef,
				'HTML::LinkExtractor' => undef,
				'Text::CSV_XS' => 0.23,
				'Class::Accessor' => 0, 
			}, # e.g., Module::Name => 1.1

    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'DeutscheBank.pm', # retrieve abstract from module
       AUTHOR     => 'Wolfgang Schlueschen <wschl@cpan.org>') : ()),
);
