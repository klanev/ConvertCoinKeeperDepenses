BEGIN { push @INC, '.'; }
use Text::CSV::Encoded;
use Excel::Writer::XLSX;
use Excel::Writer::XLSX::Utility;
use Getopt::Long;
use Encode;
use utf8;
use strict;

use Win32::Console;
Win32::Console::OutputCP(65001);
binmode(STDOUT, ":unix:utf8");

my $currency_info = {
      "RUB" => { alias => "р.", priority => 0 },
      "USD" => { alias => "\$", priority => 1 }
   };

my ( %params );
( GetOptions( \%params, "output=s" , 'after=s', 'before=s', 'rus', 'rate=s%', 'travel-start=s', 'travel-end=s', 'squash-travel' ) && @ARGV == 1 )
   || die "Usage: convert <coin keeper csv> [-after <start date>] [-before <end date>] [--rus] [--rate <currency>=<rate>] [--travel-start <travel start date> --travel-end <travel-end-date>] [--squash-travel]\n";

my $input_file = $ARGV[0];

my $after = $params{after};
my $before = $params{before};

my @depenses;
my @incomes;
my @in_transfers;

my $input_data = load_csv($input_file);

my $rates = $params{rate};
$rates = {} unless defined $rates;

my %squashed_travel_depenses;

for my $item (@{ $input_data->{log} })
{
   my $date = $item->{date};
   my $type = $item->{type};
   my $from = $item->{from};
   my $to = $item->{to};
   my $descr = $item->{descr};

   next unless
      ( ! defined $after || 1 != compare_date( $after, $date ) ) &&
      ( ! defined $before || -1 != compare_date( $before, $date ) );

   if(!!%squashed_travel_depenses && defined $params{'travel-end'} && 1 == compare_date($date, $params{'travel-end'}))
   {
      push @depenses, get_squashed_travel_depenses($after, \%squashed_travel_depenses);
   }   

   next if ($to eq "Мое") || ($to eq "Мое (\$)") || ($descr =~ /\(скрыть\)/) || ($from eq "Income" and $to eq "Копилка");
   next if $to eq "Неучтенные";

   next if($from eq "Income" and $descr =~ /^кешбек/i);

   if($type eq "Перевод")
   {
      (push @incomes, $item) if $from eq "Income";
      
      (push @in_transfers, $item) if $from eq "от Евгении";
   }
   elsif($type eq "Расход")
   {
      fix_transfer_travel_tag($item, \%params);

      fix_transfer_by_rates($item, $rates);

      next if squash_travel_depense($item, \%params, \%squashed_travel_depenses);

      if($to eq "Евгении")
      {
         $item->{descr} = "Транш, ".$item->{descr} unless ($item->{descr} =~ /транш/i);
      }
      if($to eq "Лизе")
      {
         $item->{descr} = "Лизе, ".$item->{descr} unless ($item->{descr} =~ /транш/i);
      }

      push @depenses, $item;
   }
   else
   {
      die "Unknown type: $type";
   }
}

push @depenses, get_squashed_travel_depenses($before, \%squashed_travel_depenses);

sort_log(\@depenses);

sort_log(\@incomes);

my @currencies = keys %{ { (map { $_->{currency_from} => undef, $_->{currency_to} => undef } @depenses) } };
@currencies = sort { compare_currencies($a, $b) } @currencies;
print "Currencies:\"".join('", "', @currencies)."\"\n";

my $depincs = Excel::Writer::XLSX->new( 'depincs.xlsx' );
die "Can't create output file" unless defined $depincs;

my $dep_cols = @currencies * get_statictics_columns_count() - 1;

my $depenses_sheet = $depincs->add_worksheet("Расходы");
$depenses_sheet->set_column(0, 0, 50);
$depenses_sheet->set_column(1, 1 + $dep_cols, 10);
$depenses_sheet->set_column(2 + $dep_cols, 2 + $dep_cols, 20);
$depenses_sheet->set_column(3 + $dep_cols, 5 + $dep_cols, 10);
$depenses_sheet->set_column(6 + $dep_cols, 6 + $dep_cols, 20);
 
my $bold_fmt = $depincs->add_format();
$bold_fmt->set_bold();

$depenses_sheet->write_row(
   0, 0,
   ["", "Дата", @{create_depense_header(\@currencies, get_statictics_columns_count())}, "Примечание", "Дата", "Поступления, р.", "Примечание"],
   $bold_fmt);

write_xslx_log($depincs, $depenses_sheet, 1, 0, \@depenses, 
   [
      { getter => \&create_descr, type => '' },
      'date',
      { getter => (sub { return create_depense(@_, \@currencies, get_statictics_columns_count()); }), type => 'sum' },
      { getter => \&create_notes, type => '' }
   ]);

write_xslx_log($depincs, $depenses_sheet, 1, 3 + $dep_cols, \@incomes, ['date', 'sum_from', 'descr']);

write_statistics($depincs, $depenses_sheet, \@depenses, \@incomes, \@currencies);

my $in_transfers_sheet = $depincs->add_worksheet("Входящие транши");
$in_transfers_sheet->set_column(0, 0, 50);
$in_transfers_sheet->set_column(1, 2, 10);

sort_log(\@in_transfers);

$in_transfers_sheet->write_row(0, 0, ["", "Дата", "Расходы, р.", "Примечание"], $bold_fmt);

write_xslx_log($depincs, $in_transfers_sheet, 1, 0, \@in_transfers, ['descr', 'date', 'sum_from']);
 
$depincs->close();

exit 0;

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

sub sort_log
{
   my($data) = @_;

   @$data = sort { compare_date( $a->{date}, $b->{date} ) } @$data;
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

sub convert_date_to_ISO8601
{
   my( $date ) = @_;

   return sprintf("%04d-%02d-%02dT00:01", reverse @{ split_date($date) });
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

sub get_currency_priority
{
   my($id) = @_;

   my $info = $currency_info->{$id};

   return defined($info) ? $info->{priority} : 1000;
}

sub get_currency_name
{
   my($id) = @_;

   my $info = $currency_info->{$id};

   return defined($info) ? $info->{alias} : $id;
}

sub compare_currencies
{
   my($l, $r) = @_;

   my $l_prio = get_currency_priority($l);
   my $r_prio = get_currency_priority($r);

   return -1 if $l_prio < $r_prio;
   return 1 if $l_prio > $r_prio;
   return $l cmp $r;
}

#################################################

sub write_statistics
{
   my($depincs, $depenses_sheet, $depenses, $incomes, $currencies) = @_;

   my $res_fmt = $depincs->add_format();
   $res_fmt->set_bold();
   $res_fmt->set_align('left');

   my $start_row = 1 + max(scalar(@$depenses), scalar(@$incomes));

   for my $currency_index(0..$#$currencies)
   {
      my $depense_col = 2 + $currency_index * get_statictics_columns_count();
      my $depense_stats = calc_depence_statistics($depenses, $start_row, $currencies->[$currency_index], $depense_col);

      write_rows(
         $depincs,
         $depenses_sheet,
         $start_row,
         0,
         [map { [$_->[0]] } @$depense_stats],
         $res_fmt);

      write_rows(
         $depincs,
         $depenses_sheet,
         $start_row,
         $depense_col,
         [map { [@$_[2..$#$_]] } @$depense_stats],
         $res_fmt);

      for my $row(@$depense_stats)
      {
         print "\"".join("\", \"", @$row)."\"\n";
      }
   }

   my $incomes_stats = calc_income_statistics($incomes, $start_row, $currencies);
   write_rows($depincs, $depenses_sheet, $start_row, 2 + (scalar(@currencies) * get_statictics_columns_count()), $incomes_stats, $res_fmt);
}

sub write_rows
{
   my($depincs, $depenses_sheet, $row, $col, $rows, $fmt) = @_;

   for(@$rows)
   {
      $depenses_sheet->write_row($row, $col, $_, $fmt);

      ++$row;
   }
}

sub get_statictics_columns_count
{
   return 2;
}

sub calc_depence_statistics
{
   my($depenses, $row, $currency, $col) = @_;

   my $dep_len = @$depenses;

   my $partitions = create_partitions(
      $depenses,
      [
         {                                           destinations => ["Евгении"] },
         { name => "Сумма (д/Лизы)"                , tag => "Лиза", destinations => ["Лизе"],            priority => 2 },
         { name => "Сумма (д/Гриши)"               , tag => "Гриша",                                     priority => 2 },
         { name => "Сумма (д/Саши)"                , tag => "Саша",                                      priority => 2 },
         { name => "Сумма (продукты)"              , destinations => ["Groceries", "Eating outside"],    priority => 4 },
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
         { name => ""                              , tag => "Саша", destinations => ["Здоровье"],        priority => 3, conditions => "all"  },
         { name => ""                              , tag => "Гриша",destinations => ["Здоровье"],        priority => 3, conditions => "all"  },
         { name => ""                              , tag => "Лиза", destinations => ["Здоровье"],        priority => 3, conditions => "all" },
         { name => "Сумма (Благотворительность)"   , destinations => ["Благотворительность"] },
         { name => "Сумма (\"Мистолово\")"         , tag => "ОхтинскоеРаздолье" },
         { name => "Сумма (\"Водолей-2\")"         , tag => "Водолей-2",                                 priority => 4 },
         { name => "Сумма (\"Колумб\")"            , tag => "Колумб",                                    priority => 4 },
         { name => "Сумма (отпуск)"                , tag => "отпуск",                                    priority => 5 }
      ],
      $currency,
      $row + 4,
      $col);


   if($partitions->[$#$partitions - 1]->[$col] eq '0') # remove Vacation line if empty
   {
      splice @$partitions, $#$partitions - 1, 1;
   }

   my $stat_line = $row + 1;
   my $sum_without_transh_line   = $stat_line + 1;
   my $sum_child_line_first      = $sum_without_transh_line + 2;
   my $sum_child_line_last       = $sum_child_line_first + 2;
   my $sum_car_tlcp_line         = $sum_without_transh_line + 6;
   my $sum_car_sho_line          = $sum_without_transh_line + 7;
   my $sum_flat_line             = $sum_without_transh_line + 10;
   my $sum_medicine_line         = $sum_without_transh_line + 16;
   my $sum_other_immovable_first = $sum_without_transh_line + 18;
   my $sum_other_immovable_last  = $sum_other_immovable_first + 2;

   my $res = [
      [],
      ["Сумма", "", "=".get_sum(\%params)."(".xl_rowcol_to_cell(1, $col).":".xl_rowcol_to_cell($dep_len, $col).")"],
      ["В т.ч. б/\"траншей\"", "", "=".xl_rowcol_to_cell($stat_line, $col)."-".create_stat_by_destinations($depenses, ["Евгении"], $currency, $col)],
      ["Сумма б/\"траншей\"-недвиж.-TLCP-медицина-ШО", "",
         "=".xl_rowcol_to_cell($sum_without_transh_line, $col).
         "-".xl_rowcol_to_cell($sum_flat_line, $col).
         "-".get_sum(\%params)."(".
            xl_rowcol_to_cell($sum_other_immovable_first, $col).":".xl_rowcol_to_cell($sum_other_immovable_last, $col).")".
         "-".xl_rowcol_to_cell($sum_car_tlcp_line, $col).
         "-".xl_rowcol_to_cell($sum_medicine_line, $col).
         "-".get_sum(\%params)."(".
            xl_rowcol_to_cell($sum_child_line_first, $col + 1).":".xl_rowcol_to_cell($sum_child_line_last, $col + 1).")".
         "-".xl_rowcol_to_cell($sum_car_sho_line, $col)],
      @$partitions
   ];

   push @{ $res->[$#$res] },
      "=".xl_rowcol_to_cell($sum_without_transh_line, $col).
      "-".get_sum(\%params)."(".
         xl_rowcol_to_cell($sum_without_transh_line + 2, $col).":".xl_rowcol_to_cell(($sum_without_transh_line + 2) + (@$partitions - 1) - 1, $col).")";

   return $res;
}

sub calc_income_statistics
{
   my($incomes, $row, $currencies) = @_;

   my $inc_len = @$incomes;

   my $col = 3 + (scalar(@currencies) * get_statictics_columns_count());

   my $res = [
      [],
      ["Сумма", "=".get_sum(\%params)."(".
         xl_rowcol_to_cell(1, $col).":".xl_rowcol_to_cell($inc_len, $col).")"]
   ];

   return $res;
}

sub create_stat_by_destinations
{
   my($depenses, $tos, $currency, $col) = @_;

   my @indexes = grep {
         my $info = $depenses->[$_];

         ($info->{currency_from} eq $currency) && find_in_array($info->{to}, $tos);
      } (0..$#$depenses);

   return create_sum_of_parts([map { xl_rowcol_to_cell($_ + 1, $col) } @indexes]);
}

sub find_in_array
{
   my($sample, $array) = @_;

   return 0 != (grep { $_ eq $sample } @$array);
}

sub create_partitions
{
   my($depenses, $scheme, $currency, $row, $col) = @_;

   my @scheme_parts = map { [] } @$scheme;
   my $other_parts = [];

   foreach my $index (0..$#$depenses)
   {
      my $depense_info = $depenses->[$index];

      next if $depense_info->{currency_from} ne $currency;

      my @partitions_fit_indexes = grep { is_depense_fits_partition($depense_info, $scheme->[$_]) } (0..$#$scheme);

      @partitions_fit_indexes = sort { get_priority($scheme->[$b]) <=> get_priority($scheme->[$a]) } @partitions_fit_indexes;

      my $max_priority = 0 != @partitions_fit_indexes ? get_priority($scheme->[$partitions_fit_indexes[0]]) : 0;

      @partitions_fit_indexes = grep { get_priority($scheme->[$_]) >= $max_priority } @partitions_fit_indexes;

      my $concurrency_factor = @partitions_fit_indexes;

      my $part = xl_rowcol_to_cell($index + 1, $col).($concurrency_factor > 1 ? "/".$concurrency_factor : "");

      foreach(@partitions_fit_indexes)
      {
         push_part($scheme_parts[$_], $part);
      }

      if(0 == @partitions_fit_indexes)
      {
         push_part($other_parts, $part);
      }
   }

   my $partitions = [
      (map {
         [ $scheme->[$_]->{name}, "", "=".create_sum_of_parts($scheme_parts[$_]) ]
      } grep {
         defined $scheme->[$_]->{name}
      } (0..$#$scheme)),
      [ "Сумма (остальное)", "", "=".create_sum_of_parts($other_parts)]
   ];


   my $row_offset = 0;
   for(0..$#$partitions)
   {
      if(defined $partitions->[$_])
      {
         my $column_offset = 1;

         while(($_ + $column_offset) <= $#$partitions && ($partitions->[$_ + $column_offset]->[0] eq ""))
         {
            push @{ $partitions->[$_] }, $partitions->[$_ + $column_offset]->[2];

            $partitions->[$_ + $column_offset] = undef;

            ++$column_offset;
         }

         if($column_offset != 1)
         {
            $partitions->[$_]->[2] = ($partitions->[$_]->[2])."+".
               get_sum(\%params)."(".
                  xl_rowcol_to_cell($row + $row_offset, $col + 1).":".
                  xl_rowcol_to_cell($row + $row_offset, $col + $column_offset - 1).")";
         }

         ++$row_offset;
      }
   }

   return [ grep { defined $_ } @$partitions ];
}

sub is_depense_fits_partition
{
   my($depense_info, $partition) = @_;

   if($partition->{conditions} eq "all")
   {
      return 0 if exists $partition->{tag} && (not is_depense_fits_tag($depense_info, $partition->{tag}));

      return 0 if exists $partition->{destinations} && (not is_depense_fits_destinations($depense_info, $partition->{destinations}));

      return 1;
   }

   return 1 if((exists $partition->{tag}) && is_depense_fits_tag($depense_info, $partition->{tag}));

   return 1 if((exists $partition->{destinations}) && is_depense_fits_destinations($depense_info, $partition->{destinations}));

   return 0;
}
   
sub is_depense_fits_tag
{
   my($depense_info, $tag) = @_;

   return exists $depense_info->{tags} && find_in_array($tag, $depense_info->{tags});
}

sub is_depense_fits_destinations
{
   my($depense_info, $destinations) = @_;

   return find_in_array($depense_info->{to}, $destinations);
}

sub create_sum_of_parts
{
   my($parts) = @_;

   return @$parts != 0 ? get_sum(\%params)."(".join(',', @$parts).")" : "0";
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

   my $log = [];
   my $account_names = {};

   open( my $in, '<', $input_file ) or die "Can't open $input_file";
   binmode $in;

   my $csv_in = Text::CSV->new({ binary => 1, auto_diag => 1 });

   while(my $columns = $csv_in->getline( $in ))
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
      my $sum_from = to_dot_num($columns->[5]);
      my $currency_from = $columns->[6];
      my $sum_to = to_dot_num($columns->[7]);
      my $currency_to = $columns->[8];

      push @$log, {
         date => $date,
         type => $type,
         from => $from,
         to => $to,
         descr => $descr,
         tags => [split /, */, $tags],
         sum_from => $sum_from,
         sum_to => $sum_to,
         currency_from => $currency_from,
         currency_to => $currency_to };
   }

   while(my $columns = $csv_in->getline( $in ))
   {
      next if @$columns == 0;
   }

   while(my $columns = $csv_in->getline( $in ))
   {
      next if $columns->[0] eq "Name";
      next if $columns->[0] eq "Название";
      last if 0 == @$columns;

      $account_names->{$columns->[0]} = undef;
   }

   close( $in );

   return { log => $log, account_names => $account_names };
}

sub trim_line
{
   my($line) = @_;

   return $line =~ /^(.*)$/ ? $1 : $line;
}

sub to_dot_num
{
   my($val) = @_;
   return $val =~ s/\,/\./r;
}

sub max_num
{
   my($a, $b) = @_;
   return $a < $b ? $b : $a;
}

sub write_xslx_log
{
   my($dst_file, $dst_worksheet, $row, $col, $src_log, $fields) = @_;

   my $num_fmt = $dst_file->add_format();
   $num_fmt->set_align('left');

   my $date_fmt = $dst_file->add_format();
   $date_fmt->set_align('left');
   $date_fmt->set_num_format('dd.mm');

   my $cur_date = undef;

   for my $log_item (@$src_log)
   {
      my $src_col = -1;

      for my $field (@$fields)
      {
         my $value;
         my $type;
         if(ref($field) eq '')
         {
            $value = $log_item->{$field};
            $type = $field;
         }
         elsif(ref($field) eq 'HASH')
         {
            $value = $field->{getter}->($log_item);
            $type = $field->{type};
         }
         else
         {
            die "Unknown field format: ".ref $field;
         }

         my @values;
         if(ref($value) eq '')
         {
            @values = ($value);
         }
         elsif(ref($value) eq 'ARRAY')
         {
            @values = (@$value);
         }
         else
         {
            die "Value of unknown type extracted: ".ref $value;
         }

         for my $val(@values)
         {
            ++$src_col;

            next unless defined $val;

            if($type eq 'date')
            {
               die "Multiple dates not supported" unless 1 == @values;

               if($val ne $cur_date)
               {
                  $dst_worksheet->write_date_time($row, $col + $src_col, convert_date_to_ISO8601($val), $date_fmt);
                  $cur_date = $val;
               }
            }
            elsif($type =~ /^sum/)
            {
               $dst_worksheet->write_number($row, $col + $src_col, to_dot_num($val), $num_fmt);
            }
            else
            {
               $dst_worksheet->write($row, $col + $src_col, $val);
            }
         }
      }

      ++$row;
   }
}

sub create_descr
{
   my($item) = @_;

   if(($item->{descr}) =~ /^(.*)\,([^\,]*)/)
   {
      return $1;
   }
   else
   {
      return $item->{descr};
   }
}

sub create_notes
{
   my($item) = @_;

   if(($item->{descr}) =~ /^(.*)\,([^\,]*)/)
   {
      return $2;
   }
   else
   {
      return "";
   }
}

sub get_currency_index
{
   my($currency, $currencies) = @_;

   my $index = -1;

   for(@$currencies)
   {
      ++$index;

      last if $_ eq $currency;
   }

   return $index;
}

sub create_depense
{
   my($item, $currencies, $stat_col_count) = @_;

   my $result = [(undef) x (scalar(@$currencies) * $stat_col_count - 1)];

   if($item->{type} eq "Расход")
   {
      my $from_index = get_currency_index($item->{currency_from}, $currencies);
      die "Wrong currency_from" unless $from_index != -1;

      $result->[$from_index * $stat_col_count] = $item->{sum_from};
   }
   else
   {
      die;
   }

   return $result;
}

sub create_depense_header
{
   my($currencies, $stat_col_count) = @_;

   my $result = [map { "Расходы, ".get_currency_name($_), (undef) x ($stat_col_count - 1) } @$currencies];

   pop @$result;

   return $result;
}

sub fix_transfer_by_rates
{
   my($transfer, $rates) = @_;

   my $sum_from = $transfer->{sum_from};
   my $currency_from = $transfer->{currency_from};

   my $from_fixed = fix_transfer_sum_by_rates($transfer, $rates, 'sum_from', 'currency_from');
   my $to_fixed = fix_transfer_sum_by_rates($transfer, $rates, 'sum_to', 'currency_to');

   if ($from_fixed or $to_fixed)
   {
      $transfer->{descr} = sprintf('(%.2f %s)', $sum_from, get_currency_name($currency_from)).$transfer->{descr};
   }   
}

sub fix_transfer_sum_by_rates
{
   my($transfer, $rates, $sum_name, $currency_name) = @_;

   my $currency = $transfer->{$currency_name};
   my $rate = $rates->{$currency};
   
   if (($currency ne 'RUB') and defined($rate))
   {
      $transfer->{$currency_name} = 'RUB';
      $transfer->{$sum_name} = sprintf('%.2f', $transfer->{$sum_name} * $rate);

      return 1;
   }

   return 0;
}

sub fix_transfer_travel_tag
{
   my($item, $params) = @_;

   if (!find_in_array('отпуск', $item->{tags}) && is_travel($item, $params))
   {
      push @{ $item->{tags} }, 'отпуск';
   }
}

sub is_travel
{
   my($item, $params) = @_;

   return 0 if $item->{currency_from} eq 'RUB';
   
   return 0 unless is_in_travel_period($item->{date}, $params);

   return 0 if
      find_in_array('не_отпуск', $item->{tags});

   return 1;
}

sub is_in_travel_period
{
   my($date, $params) = @_;

   my $travel_start = $params->{'travel-start'};
   my $travel_end = $params->{'travel-end'};

   return
      (defined $travel_start || defined $travel_end) &&
      (!defined $travel_start || 1 != compare_date($travel_start, $date)) &&
      (!defined $travel_end || -1 != compare_date($travel_end, $date));
}

sub squash_travel_depense
{
   my($item, $params, $collector) = @_;

   if (find_in_array('отпуск', $item->{tags}) &&
       is_in_travel_period($item->{date}, $params))
   {
      $collector->{$item->{currency_from}} += $item->{sum_from};

      return 1;
   }

   return 0;
}

sub get_squashed_travel_depenses
{
   my($date, $collector) = @_;

   my @result = map { {
      date => $date,
      type => "Расход",
      from => undef,
      to => undef,
      descr => "Траты в отпуске, ".get_currency_name($_),
      tags => ['отпуск'],
      sum_from => $collector->{$_},
      sum_to => $collector->{$_},
      currency_from => $_,
      currency_to => $_ }
   } keys %$collector;

   %$collector = ();

   return @result;
}