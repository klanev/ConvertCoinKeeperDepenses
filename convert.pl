use Text::CSV::Encoded;
use Getopt::Long;
use Encode;
use utf8;
use strict;


my ( %params );
( GetOptions( \%params, "output=s" , 'after=s', 'before=s' ) && @ARGV == 1 )
	|| die "Usage: convert <coin keeper csv> [-after <start date>] [-before <end date>]-\n";

my $input_file = $ARGV[0];

my $after = $params{after};
my $before = $params{before};

my @depenses;
my @incomes;
my @in_transfers;

my %account_names = ("Кошелёк" => undef, "Зарплатная карта" => undef, "Кредитка" => undef, "Копилка" => undef, "ККБ" => undef, "Копилка (нал)" => undef);
open( my $in, '<', $input_file ) or die "Can't open $input_file";

my $csv_in = Text::CSV::Encoded->new( { encoding_in => "utf8" } );

while( my $columns = $csv_in->getline( $in ) )
{
	next if @$columns eq 2;
	next if $columns->[0] eq "Data";
	next if $columns->[0] eq "Данные";
	last if $columns->[0] eq "";
	
	my $date = convert_date( $columns->[0] );
	my $type = $columns->[1];
	my $from = $columns->[2];
	my $to = $columns->[3];
	my $note = $columns->[10];

	next unless
	   ( ! defined $after || 1 != compare_date( $after, $date ) ) &&
	   ( ! defined $before || -1 != compare_date( $before, $date ) );

	next if ($to eq "Мое") || ($note =~ /\(скрыть\)/);
	next if $to eq "Неучтенные";

	if($type eq "Перевод")
	{
	   store_row(\@incomes, $columns, \%account_names) if $from eq "Income";
	   
	   store_row(\@in_transfers, $columns, \%account_names) if $from eq "от Евгении";
	}
	elsif($type eq "Расход")
	{
	   store_row(\@depenses, $columns, \%account_names);
	}
}

close( $in );

my @cashbacks;
my @cb_depenses;
my $index = 2;

for my $row (@depenses)
{
	my $cashback = $row->[4];
	if($cashback ne "")
	{
		my $cb_percent = "H$index";
		my $dep = "(C$index/(100%-$cb_percent))";

		push @cb_depenses, $dep;
		push @cashbacks, "$dep*$cb_percent";
		
	}

	$index = $index + 1;
}

sort_depenses(\@depenses);

sort_depenses(\@incomes);
my @incs = map { [$_->[1], $_->[2], $_->[0]] } @incomes;
push @incs, [];
push @incs, ["КБ, р.", "Потрачено с ККБ, р.", ""];
push @incs, ["=".(join "+", @cashbacks), "=".(join "+", @cb_depenses), ""];

my @depincs;
push @depincs, ["", "Дата", "Расходы, р.", "Примечание", "Процент кешбек", "Дата", "Поступления, р.", "Примечание"];
my $depenses_len = @depenses;
my $incs_len = @incs;
push @depincs, map
	{                         
		[
			@{ $_ < $depenses_len ?	$depenses[$_]	: ["", "", "", "", ""] },
			@{ $_ < $incs_len ?		$incs[$_] 		: [] }
		]
	}
	0 .. (max($depenses_len, $incs_len) - 1);

@depincs = map { [$_->[0], $_->[1], $_->[2], $_->[3], $_->[5], $_->[6], $_->[7], $_->[4]] } @depincs;

write_out("depincs.txt", \@depincs);

sort_depenses(\@in_transfers);
write_out("in_transfers.txt", \@in_transfers);

###########################################################

sub max
{
	my($a, $b) = @_;

	return $a < $b ? $b : $a;
}

sub min
{
	my($a, $b) = @_;

	return $a < $b ? $a : $b;
}

###########################################################

sub store_row
{
   my( $acc, $columns, $account_names ) = @_;
   
   my $from = $columns->[2];
   my $descr = $columns->[10];
   my $to = $columns->[3];
   my $tags = $columns->[4];
   my $sum = $columns->[5];
   
   my $notes;
   
   if(($to eq "") || (exists $account_names->{$to}))
   {
      $notes = $tags;
   }
   elsif($tags eq "")
   {
      $notes = $to;
   }
   else
   {
      $notes = $to.".".$tags;
   }

   my $index = @$acc + 2;

   my $cashback;
   if($from eq 'ККБ' and $to ne 'Евгении')
   {
 		$cashback = '1%';

   	if(($descr =~ /Бензин/) || ($descr =~ /Солярка/))
   	{
   		$cashback = '10%';
   	}
   	elsif($descr =~ /Обед/)
   	{
   		$cashback = '5%';
   	}

   	my $cb_percent = "H$index";
   	$sum = "=$sum*(100%-$cb_percent)";
   }

   push @$acc, [ $descr, convert_date( $columns->[0] ), $sum, $notes, $cashback ];
}

sub sort_depenses
{
	my($data) = @_;

	@$data = sort { compare_date( $a->[1], $b->[1] ) } @$data;
}

sub write_out
{
   my( $output_file, $data ) = @_;
   
   my $csv_out = Text::CSV::Encoded->new( { encoding_out => "utf8", eol => "\r\n" } );

   open( my $out, '>', $output_file ) or die "Can't create $output_file";

   foreach( @$data )
   {
	   $csv_out->print( $out, $_ );
   }

   close( $out );   
}

sub convert_date
{
	my( $date ) = @_;

	die "Invalid date format \"$date\"" unless ( $date =~ /^([0-9]+)\.([0-9]+)\.([0-9]+)$/ );

	return sprintf("%02d.%02d.%04d", $1, $2, $3 );
}

sub split_date
{
	my( $date ) = @_;

	die "Invalid date format \"$date\"" unless ( $date =~ /^([0-9]{2,2})\.([0-9]{2,2})\.([0-9]{4,4})$/ );

	return [ $1, $2, $3 ];
}

sub lex_compare
{
	my( $a, $b ) = @_;

	my $i = 0;

	for(; $i < @$a && $i < @$b; ++ $i )
	{
		my $cr = $a->[$i] <=> $b->[$i];

		return $cr unless $cr == 0;
	}

	return ( @$a - $i ) <=> ( @$b - $i );
}

sub compare_date
{
	my( $a, $b ) = @_;

	return lex_compare( [ reverse @{ split_date( $a ) } ], [ reverse @{ split_date( $b ) } ] );
}

