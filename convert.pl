BEGIN { push @INC, '.'; }
use Text::CSV::Encoded;
use Getopt::Long;
use Encode;
use utf8;
use strict;

use Win32::Console;
Win32::Console::OutputCP(65001);
binmode(STDOUT, ":unix:utf8");

my ( %params );
( GetOptions( \%params, "output=s" , 'after=s', 'before=s', 'rus', 'rate=s%', 'squash-travel', 'web-text', 'year=i' ) && @ARGV == 1 )
   || die "Usage: convert <coin keeper csv> [-after <start date>] [-before <end date>] [--rus] [--rate <currency>=<rate>...] [--squash-travel] [--web-text] [--year <year of report for web text>]\n";

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

my %account_names = ("Кошелёк" => undef, "Зарплатная карта" => undef, "Кредитка" => undef, "Копилка" => undef, "ККБ" => undef, "Копилка (нал)" => undef, "Раффайзен (кредит ШО)" => undef, "Кукуруза" => undef, "ЕКП" => undef, "Лента А (оф)" => undef, "Лента А (копилка)" => undef, "Binance USDT" => undef, "Bankoff" => undef, "Бакай \$" => undef, "Бакай" => undef, "BSB \$" => undef, "BSB" => undef);

my $input_data = (not $params{'web-text'}) ? load_csv($input_file) : load_web_txt($input_file, $params{year});

for my $item (@$input_data)
{
   my $date = $item->{date};
   my $type = $item->{type};
   my $from = $item->{from};
   my $to = $item->{to};
   my $descr = $item->{descr};

   next unless
      ( ! defined $after || 1 != compare_date( $after, $date ) ) &&
      ( ! defined $before || -1 != compare_date( $before, $date ) );

   next if ($to eq "Мое") || ($to eq "Мое (\$)") || ($descr =~ /\(скрыть\)/) || ($from eq "Income" and $to eq "Копилка");
   next if $to eq "Неучтенные";

   if($from eq "Income" and $descr =~ /^кешбек/i)
   {
      $prev_cashback = $item->{sum};

      next;
   }

   if($type eq "Перевод")
   {
      store_row(\@incomes, $item, \%account_names) if $from eq "Income";
      
      store_row(\@in_transfers, $item, \%account_names) if $from eq "от Евгении";
   }
   elsif($type eq "Расход")
   {
      store_row(\@depenses, $item, \%account_names);
   }
}

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

my @depincs;
push @depincs, ["", "Дата", "Расходы, р.", "Примечание", "", "Дата", "Поступления, р.", "Примечание"];
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
   my( $acc, $item, $account_names ) = @_;
   
   my $from = $item->{from};
   my $descr = $item->{descr};
   my $to = $item->{to};
   my $tags = $item->{tags};
   my $sum = $item->{sum};
   my $currency_from = $item->{currency_from};
   my $currency_to = $item->{currency_to};

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
         push @$acc, [ 'Отпуск', $item->{date}, '', '.отпуск', '' ];
      }

      return;
   }

   my $index = @$acc + 2;

   my $cashback;
   if($from eq 'ККБ' and $to ne 'Евгении' and not ($tags =~ "не в сумме трат ККБ"))
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
      elsif($tags =~ "0\%")
      {
         $cashback = '0%';
      }

      my $cb_percent = "H$index";
      $sum = "=$sum*(100%-$cb_percent)";
   }

   if($to eq 'Евгении')
   {
      if($descr eq '')
      {
         $descr = 'Транш';
      }
      else
      {
         $descr = "Транш ($descr)";
      }
   }

   $descr =~ s/[\r\n]/ /g;

   push @$acc, [ $descr, $item->{date}, $sum, $notes, $cashback ];
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
         { name => "Сумма (д/Лизы)"                , tag => "Лиза", destinations => ["Лизе"],            priority => 2 },
         { name => "Сумма (д/Гриши)"               , tag => "Гриша",                                     priority => 2 },
         { name => "Сумма (д/Саши)"                , tag => "Саша",                                      priority => 2 },
         { name => "Сумма (продукты взросл.)"      , destinations => ["Groceries", "Eating outside"] },
         { name => "Сумма (крузак)"                , tag => "TLCP" },
         { name => "Сумма (ШО)"                    , tag => "ШО" },
         { name => "Сумма (моб.)"                  , tag => "связь" },
         { name => "Сумма (пошив, ремонт одежды)"  , tag => "одежда" },
         { name => "Сумма (квартира)"              , tag => "Учительская" },
         { name => "Сумма (подарки к праздникам)"  , destinations => ["Подарки"] },
         { name => "Сумма (д/И.Л.)"                , tag => "И.Л." },
         { name => "Сумма (д/РА)"                  , tag => "Р.А." },
         { name => "Сумма (космет-я, парикмах.)"   , tag => "внешность" },
         { name => "Сумма (спорт, танцы)"          , tag => "спорт" },
         { name => "Сумма (медицина)"              , destinations => ["Здоровье"] },
         { name => "Сумма (Благотворительность)"   , destinations => ["Благотворительность"] },
         { name => "Сумма (\"Мистолово\")"         , tag => "ОхтинскоеРаздолье" },
         { name => "Сумма (\"Водолей-2\")"         , tag => "Водолей-2" },
         { name => "Сумма (\"Колумб\")"            , tag => "Колумб" },
         { name => "Сумма (отпуск)"                , tag => "отпуск" }
      ] );

   if($partitions->[$#$partitions - 1]->[2] eq '0') # remove Vacation line if empty
   {
      splice @$partitions, $#$partitions - 1, 1;
   }

   my $stat_line = $dep_len + 3;
   my $sum_without_transh_line   = $stat_line + 1;
   my $sum_car_tlcp_line         = $sum_without_transh_line + 6;
   my $sum_car_sho_line          = $sum_without_transh_line + 7;
   my $sum_flat_line             = $sum_without_transh_line + 10;
   my $sum_medicine_line         = $sum_without_transh_line + 16;
   my $sum_razdolie_line         = $sum_without_transh_line + 17;

   my $res = [
      ["", "", "", ""],
      ["Сумма", "", "=".get_sum(\%params)."(C2:C".($dep_len + 1).")", "", "Сумма", "=".get_sum(\%params)."(F2:F".($inc_len + 1).")"],
      ["В т.ч. б/\"траншей\"", "", "=C$stat_line-".create_stat_by_destinations($depenses, ["Евгении"])],
      ["Сумма б/\"траншей\"-кв.-TLCP-медицина-ШО", "", "=C$sum_without_transh_line-C$sum_flat_line-C$sum_razdolie_line-C$sum_car_tlcp_line-C$sum_medicine_line-C$sum_car_sho_line"],
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

sub load_csv
{
   my($input_file) = @_;

   my $res = [];

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
      my $descr = $columns->[10];
      my $tags = $columns->[4];
      my $sum = $columns->[5];
      my $currency_from = $columns->[6];
      my $currency_to = $columns->[8];

      push @$res, {
         date => $date,
         type => $type,
         from => $from,
         to => $to,
         descr => $descr,
         tags => $tags,
         sum => $sum,
         currency_from => $currency_from,
         currency_to => $currency_to };
   }

   close( $in );

   return $res;
}

sub load_web_txt
{
   my($input_file, $year) = @_;

   my @res;

   my %months = (
      "января" => 1,    "февраля" => 2,   "марта" => 3,  "апреля" => 4,
      "мая" => 5,       "июня" => 6,      "июля" => 7,   "августа" => 8,
      "сентября" => 9,  "октября" => 10,  "ноября" => 11,"декабря" => 12
   );

   my %incomes;
   @incomes{'Income', 'от Евгении', 'Долг', 'от Лизы'} = ();

   ($year = 1900 + (localtime)[5]) unless defined $year;

   open(my $in, '<:encoding(UTF-8)', $input_file) or die "Can't open $input_file";

   while(my $line = <$in>)
   {
      die "No day header found at $." unless $line =~ /^[А-ЯA-Z]+(\d+) (.*)$/;
      my $day = $1;
      my $month = $months{$2};
      die "Wrong month \'$2\' at $." unless defined $month;

      my $date = sprintf "%2.2d.%2.2d.%4.4d", $day, $month, $year;

      my $ln = <$in>;

      while(1)
      {
         my $from = trim_line($ln);

         print "from = \'$from\'\n";

         last if $from =~ /^(\$\s+)?([\−\-] )?\d/;

         $ln = <$in>;

         my $to = trim_line($ln);

         $ln = <$in>;

         die "Wrong sum (\'$ln\') at $." unless trim_line($ln) =~ /^(\$\x{200e}\s*)?(\d{1,3}( \d{3})*([\.\,]\d{2})?)(\x{200e}\s*\x{20bd})?$/;
         my $sum = $2;
         $sum =~ s/ //g;

         my @tags;

         $ln = <$in>;
         if($ln =~ /^\#/)
         {
            @tags = map { die "Wrong tag \'$_\' at $." unless /^\#(.*)/; $1 } (split / /, $ln);

            $ln = <$in>;
         }

         my $descr = trim_line($ln);
         if((not exists $account_names{$descr}) and (not exists $incomes{$descr}) and (not ($descr =~ /^([\−\-] )?\d/)))
         {
            $ln = <$in>;
         }
         else
         {
            $descr = undef;
         }

         print "$date: '$from' -> '$to', sum=$sum, tags = ".join(' ', @tags).", descr = \'$descr\'\n";

         push @res, {
            date => $date,
            type => (((exists $incomes{$from}) or (exists $account_names{$from})) and (exists $account_names{$to}) ? "Перевод" : "Расход"),
            from => $from,
            to => $to,
            descr => $descr,
            tags => join(', ', @tags),
            sum => $sum,
            currency_from => 'RUB',
            currency_to => 'RUB' };
      }

      my $skip_ln = <$in>;
      $skip_ln = <$in>;
      $skip_ln = <$in>;
   }

   close($in);

   return [reverse @res];
}

sub trim_line
{
   my($line) = @_;

   return $line =~ /^(.*)$/ ? $1 : $line;
}