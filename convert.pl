BEGIN { push @INC, '.'; }
use Text::CSV::Encoded;
use Getopt::Long;
use Encode;
use utf8;
use strict;


my ( %params );
( GetOptions( \%params, "output=s" , 'after=s', 'before=s', 'rus', 'rate=s%', 'squash-travel' ) && @ARGV == 1 )
   || die "Usage: convert <coin keeper csv> [-after <start date>] [-before <end date>] [--rus] [--rate <currency>=<rate>...] [--squash-travel]\n";

my $input_file = $ARGV[0];

my $after = $params{after};
my $before = $params{before};

my %rates = %{ $params{rate} or {} };

my @depenses;
my @incomes;
my @in_transfers;

my $prev_cashback;
my $travel_index;
my $travel_sum;

my %account_names = ("Кошелёк" => undef, "Зарплатная карта" => undef, "Кредитка" => undef, "Копилка" => undef, "ККБ" => undef, "Копилка (нал)" => undef, "Раффайзен (кредит ШО)" => undef);
open( my $in, '<', $input_file ) or die "Can't open $input_file";
binmode $in;

my $csv_in = Text::CSV->new({ binary => 1, auto_diag => 1 });

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

   if($from eq "Income" and $note =~ /^кешбек/i)
   {
      $prev_cashback = $columns->[5];

      next;
   }

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

if(defined $travel_index)
{
   my $travel_sum_ = $travel_sum;
   $travel_sum_ =~  s/\./\,/g;
   $depenses[$travel_index]->[2] = $travel_sum_;
}

my @cashbacks_1;
my @cashbacks_5_10;
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

      my $cashback_val = "$dep*$cb_percent";

      if($cashback == "1%")
      {
         push @cashbacks_1, $cashback_val;
      }
      else
      {
         push @cashbacks_5_10, $cashback_val;
      }     
   }

   $index = $index + 1;
}

sort_depenses(\@depenses);

sort_depenses(\@incomes);
my @incs = map { [$_->[1], $_->[2], $_->[0]] } @incomes;
my $cb_index = 5 + @incs;
push @incs, [];
push @incs, ["Реальный кешбек, р.", "?", $prev_cashback];
push @incs, ["КБ, р.", "Потрачено с ККБ, р.", ""];
push @incs, ["=E".($cb_index + 1)."+E".($cb_index + 2), "=".(join "+", @cb_depenses), ""];
push @incs, ["=".(join "+", @cashbacks_1), "1%", ""];
push @incs, ["=".(join "+", @cashbacks_5_10), "5%-10%", ""];

my @depincs;
push @depincs, ["", "Дата", "Расходы, р.", "Примечание", "Процент кешбек", "Дата", "Поступления, р.", "Примечание"];
my $depenses_len = @depenses;
my $incs_len = @incs;
push @depincs, map
   {                         
      [
         @{ $_ < $depenses_len ? $depenses[$_]  : ["", "", "", "", ""] },
         @{ $_ < $incs_len ?     $incs[$_]      : [] }
      ]
   }
   0 .. (max($depenses_len, $incs_len) - 1);

@depincs = map { [$_->[0], $_->[1], $_->[2], $_->[3], $_->[5], $_->[6], $_->[7], $_->[4]] } @depincs;

push @depincs, @{ calc_statistics(\@depenses, \@incomes) };

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
   my $currency_from = $columns->[6];
   my $currency_to = $columns->[8];

   my $notes;

   $tags =~ s/Новая ШО/ШО/sg;
   $tags =~ s/Новый автомобиль/TLCP/sg;
   
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

   die "Cannot process incoming transactions in other currency($currency_to)"
      if($currency_to ne 'RUB');

   if($currency_from ne 'RUB')
   {
      if($rates{$currency_from})
      {
         $sum =~ s/\,/\./g;
         $descr = $descr."($sum $currency_from)";
         $sum = $sum * $rates{$currency_from};
         $sum =~ s/\./\,/g;
      }
      else
      {
         die "Currency($currency_from) rate is not set\n";
      }
   }

   if($params{'squash-travel'} and (grep { $_ eq 'отпуск' } split(/, */, $tags)))
   {
      my $sum_ = $sum;
      $sum_ =~ s/\,/\./g;
      $travel_sum = $travel_sum + $sum_;

      if(not defined $travel_index)
      {
         $travel_index = @$acc;
         push @$acc, [ 'Отпуск', convert_date( $columns->[0] ), '', '.отпуск', '' ];
      }

      return;
   }

   my $index = @$acc + 2;

   my $cashback;
   if($from eq 'ККБ' and $to ne 'Евгении')
   {
      $cashback = '1%';

      if(($descr =~ /Бензин/i) || ($descr =~ /Солярка/i) || ($tags =~ "10\%"))
      {
         $cashback = '10%';
      }
      elsif($descr =~ /Обед/i || ($descr =~ /Кофе/i) || ($tags =~ "5\%"))
      {
         $cashback = '5%';
      }

      my $cb_percent = "H$index";
      $sum = "=$sum*(100%-$cb_percent)";
   }

   $descr = 'Транш' if ($descr eq '') and ($to eq 'Евгении');

   $descr =~ s/[\r\n]/ /g;

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

#################################################

sub calc_statistics
{
   my($depenses, $incomes) = @_;

   my $dep_len = @$depenses;
   my $inc_len = @$incomes;

   my $partitions = create_partitions(
      $depenses,
      [
         {                                           destinations => ["Евгении"] },
         { name => "Сумма (д/Лизы)"                , tag => "Лиза",                                      priority => 2 },
         { name => "Сумма (д/Гриши)"               , tag => "Гриша",                                     priority => 2 },
         { name => "Сумма (продукты взросл.)"      , destinations => ["Groceries", "Eating outside"] },
         { name => "Сумма (крузак)"                , tag => "TLCP" },
         { name => "Сумма (ШО)"                    , tag => "ШО" },
         { name => "Сумма (моб.)"                  , tag => "связь" },
         { name => "Сумма (пошив, ремонт одежды)"  , tag => "одежда" },
         { name => "Сумма (квартира)"              , destinations => ["House"] },
         { name => "Сумма (подарки к праздникам)"  , destinations => ["Подарки"] },
         { name => "Сумма (д/И.Л.)"                , tag => "И.Л." },
         { name => "Сумма (д/РА)"                  , tag => "Р.А." },
         { name => "Сумма (космет-я, парикмах.)"   , tag => "внешность" },
         { name => "Сумма (спорт, танцы)"          , tag => "спорт" },
         { name => "Сумма (медицина)"              , destinations => ["Здоровье"] },
         { name => "Сумма (квартира в ЖК \"Колумб\")", destinations => ["квартира.Колумб"] },
         { name => "Сумма (Благотворительность)"   , destinations => ["Благотворительность"] },
         { name => "Сумма (отпуск)"                , tag => "отпуск" }
      ] );

   if($partitions->[$#$partitions - 1]->[2] eq '0') # remove Vacation line if empty
   {
      splice @$partitions, $#$partitions - 1, 1;
   }

   my $stat_line = $dep_len + 3;
   my $sum_without_transh_line   = $stat_line + 1;
   my $sum_car_tlcp_line         = $sum_without_transh_line + 5;
   my $sum_car_sho_line          = $sum_without_transh_line + 6;
   my $sum_flat_line             = $sum_without_transh_line + 9;
   my $sum_medicine_line         = $sum_without_transh_line + 15;

   my $res = [
      ["", "", "", ""],
      ["Сумма", "", "=".get_sum(\%params)."(C2:C".($dep_len + 1).")", "", "Сумма", "=".get_sum(\%params)."(F2:F".($inc_len + 1).")"],
      ["В т.ч. б/\"траншей\"", "", "=C$stat_line-".create_stat_by_destinations($depenses, ["Евгении"])],
      ["Сумма б/\"траншей\"-кв.-TLCP-медицина-ШО", "", "=C$sum_without_transh_line-C$sum_flat_line-C$sum_car_tlcp_line-C$sum_medicine_line-C$sum_car_sho_line"],
      @$partitions
   ];

   push @{ $res->[$#$res] }, "=C$sum_without_transh_line-".get_sum(\%params)."(C".($sum_without_transh_line + 2).":C".(($sum_without_transh_line + 2) + (@$partitions - 1) - 1).")";

   return $res;
}

sub dep_index_to_ref
{
   my($index) = @_;

   return "C".($index + 2);
}

sub parse_dep_notes
{
   my($line) = @_;

   my $notes = $line->[3];
   ($notes =~ /^([^\.]*)(\.(.*))?$/) or die "Failed to parse notes";
   my $to = $1;
   my $tags = $3;
   my @tags = split /, */, $tags;

   return { to => $to, tags => \@tags };
}

sub create_stat_by_destinations
{
   my($depenses, $tos) = @_;

   my @indexes = grep {
         my $line = $depenses->[$_];
         my $info = parse_dep_notes($line);

         find_in_array($info->{to}, $tos);
      } (0..$#$depenses);

   return get_sum(\%params)."(".join(';', map { dep_index_to_ref($_) } @indexes).")";
}

sub find_in_array
{
   my($sample, $array) = @_;

   return 0 != (grep { $_ eq $sample } @$array);
}

sub create_partitions
{
   my($depenses, $scheme) = @_;

   my @scheme_parts = map { [] } @$scheme;
   my $other_parts = [];

   foreach my $index (0..$#$depenses)
   {
      my $depense_info = parse_dep_notes($depenses->[$index]);

      my @partitions_fit_indexes = grep { is_depense_fits_partition($depense_info, $scheme->[$_]) } (0..$#$scheme);

      sort { get_priority($scheme->[$b]) <=> get_priority($scheme->[$a]) } @partitions_fit_indexes;

      my $max_priority = 0 != @partitions_fit_indexes ? get_priority($scheme->[$partitions_fit_indexes[0]]) : undef;

      @partitions_fit_indexes = grep { $scheme->[$_]->{priority} >= $max_priority } @partitions_fit_indexes;

      my $concurrency_factor = @partitions_fit_indexes;

      my $part = dep_index_to_ref($index).($concurrency_factor > 1 ? "/".$concurrency_factor : "");

      foreach(@partitions_fit_indexes)
      {
         push_part($scheme_parts[$_], $part);
      }

      if(0 == @partitions_fit_indexes)
      {
         push_part($other_parts, $part);
      }
   }

   return [
      (map {
         [ $scheme->[$_]->{name}, "", create_sum_of_parts($scheme_parts[$_]) ]
      } grep {
         defined $scheme->[$_]->{name}
      } (0..$#$scheme)),
      [ "Сумма (остальное)", "", create_sum_of_parts($other_parts)]
   ];
}

sub is_depense_fits_partition
{
   my($depense_info, $partition) = @_;

   return 1 if exists $partition->{tag} and exists $depense_info->{tags} and find_in_array($partition->{tag}, $depense_info->{tags});

   return 1 if exists $partition->{destinations} and find_in_array($depense_info->{to}, $partition->{destinations});

   return 0;
}

sub create_sum_of_parts
{
   my($parts) = @_;

   return @$parts != 0 ? "=".get_sum(\%params)."(".join(';', @$parts).")" : "0";
}

sub get_priority
{
   my($partition) = @_;

   return exists $partition->{priority} ? $partition->{priority} : 0;
}

sub push_part
{
   my($parts, $part) = @_;

   (push @$parts, $part) unless try_append_to_last_part($parts, $part);
}

sub try_append_to_last_part
{
   my($parts, $part) = @_;

   return 0 if 0 == @$parts;

   my $last = $parts->[$#$parts];

   return 0 unless $last =~ /(([A-Z]\d+)\:)?([A-Z])(\d+)$/;
   my $from = $2;
   my $last_row = $3;
   my $last_line = $4;

   return 0 unless $part =~ /^([A-Z])(\d+)$/;
   my $part_row = $1;
   my $part_line = $2;

   return 0 unless ($last_row eq $part_row) and ($last_line == ($part_line - 1));

   $parts->[$#$parts] = (defined $from ? $from : $last_row.$last_line).":".$part;

   return 1;
}

sub get_sum
{
   my($params) = @_;

   return $params->{rus} ? 'СУММ' : 'SUM';
}