package DBIx::Otogiri;
use 5.008005;
use strict;
use warnings;

use Class::Accessor::Lite (
    ro => [qw/connect_info strict/],
    rw => [qw/dbh maker/],
    new => 0,
);

use SQL::Maker;
use DBIx::Sunny;
use DBIx::Otogiri::Iterator;

sub new {
    my ($class, %opts) = @_;
    my $self = bless {%opts}, $class;
    ( $self->{dsn}{scheme},
      $self->{dsn}{driver},
      $self->{dsn}{attr_str},
      $self->{dsn}{attributes},
      $self->{dsn}{driver_dsn}
    ) = DBI->parse_dsn($self->{connect_info}[0]);
    my $strict = defined $self->strict ? $self->strict : 1;
    $self->{dbh}   = DBIx::Sunny->connect(@{$self->{connect_info}});
    $self->{maker} = SQL::Maker->new(driver => $self->{dsn}{driver}, strict => $strict);
    return $self;
}

sub _deflate_param {
    my ($self, $table, $param) = @_;
    if ($self->{deflate}) {
        $param = $self->{deflate}->({%$param}, $table, $self);
    }
    return $param;
}

sub _inflate_rows {
    my ($self, $table, @rows) = @_;
    @rows = $self->{inflate} ? map {$self->{inflate}->($_, $table, $self)} grep {defined $_} @rows : @rows;
    wantarray ? @rows : $rows[0];
}

sub select {
    my ($self, $table, $param, @opts) = @_;
    my ($sql, @binds) = $self->maker->select($table, ['*'], $param, @opts);
    $self->search_by_sql($sql, \@binds, $table);
}

*search = *select;

sub search_by_sql {
    my ($self, $sql, $binds_aref, $table) = @_;

    return DBIx::Otogiri::Iterator->new(
        db    => $self,
        sql   => $sql, 
        binds => $binds_aref,
        table => $table,
    ) unless wantarray;

    my @binds = @{$binds_aref || []};
    my $rtn = $self->dbh->select_all($sql, @binds);
    $rtn ? $self->_inflate_rows($table, @$rtn) : ();
}

sub single {
    my ($self, $table, $param, @opts) = @_;
    my ($sql, @binds) = $self->maker->select($table, ['*'], $param, @opts);
    my $row = $self->dbh->select_row($sql, @binds);
    $self->{inflate} ? $self->_inflate_rows($table, $row) : $row;
}

*fetch = *single;

sub fast_insert {
    my ($self, $table, $param, @opts) = @_;
    $param = $self->_deflate_param($table, $param);
    my ($sql, @binds) = $self->maker->insert($table, $param, @opts);
    $self->dbh->query($sql, @binds);
}

*insert = *fast_insert;

sub delete {
    my ($self, $table, $param, @opts) = @_;
    my ($sql, @binds) = $self->maker->delete($table, $param, @opts);
    $self->dbh->query($sql, @binds);
}

sub update {
    my ($self, $table, $param, @opts) = @_;
    $param = $self->_deflate_param($table, $param);
    my ($sql, @binds) = $self->maker->update($table, $param, @opts);
    $self->dbh->query($sql, @binds);
}

sub do {
    my $self = shift;
    $self->dbh->query(@_);
}

sub txn_scope {
    my $self = shift;
    $self->dbh->txn_scope;
}

sub last_insert_id {
    my ($self, $catalog, $schema, $table, $field, $attr_href) = @_;
    my $driver_name = $self->{dsn}{driver};
    if ($driver_name eq 'Pg' && !defined $table && !exists $attr_href->{sequence}) {
        my @rows = $self->search_by_sql('SELECT LASTVAL() AS lastval');
        return $rows[0]->{lastval};
    }
    return $self->dbh->last_insert_id($catalog, $schema, $table, $field, $attr_href);
}

1;
__END__

=encoding utf-8

=head1 NAME

DBIx::Otogiri - Core of Otogiri

=head1 SYNOPSIS

    use Otogiri;
    my $db = Otogiri->new(connect_info => ['dbi:SQLite:...', '', '']);
    
    $db->insert(book => {title => 'mybook1', author => 'me', ...});

    my $book_id = $db->last_insert_id;
    my $row = $db->single(book => {id => $book_id});

    print 'Title: '. $row->{title}. "\n";
    
    my @rows = $db->select(book => {price => {'>=' => 500}});
    for my $r (@rows) {
        printf "Title: %s \nPrice: %s yen\n", $r->{title}, $r->{price};
    }
    
    $db->update(book => [author => 'oreore'], {author => 'me'});
    
    $db->delete(book => {author => 'me'});
    
    ### using transaction
    do {
        my $txn = $db->txn_scope;
        $db->insert(book => ...);
        $db->insert(store => ...);
        $txn->commit;
    };

=head1 DESCRIPTION

DBIx::Otogiri is core feature class of Otogiri.

=head1 ATTRIBUTES

=head2 connect_info (required)

   connect_info => [$dsn, $dbuser, $dbpass],

You have to specify C<dsn>, C<dbuser>, and C<dbpass>, to connect to database.

=head2 strict (optional, default is 1)

In strict mode, all the expressions must be declared by using blessed references that export as_sql and bind methods like SQL::QueryMaker.

Please see METHODS section of L<SQL::Maker>'s documentation.

=head2 inflate (optional)

    use JSON;
    inflate => sub {
        my ($data, $tablename, $db) = @_;
        if (defined $data->{json}) {
            $data->{json} = decode_json($data->{json});
        }
        $data->{table} = $tablename;
        $data;
    },

You may specify column inflation logic. 

Specified code is called internally when called select(), search_by_sql(), and single().

C<$db> is Otogiri instance, you can use Otogiri's method in inflate logic.

=head2 deflate (optional)

    use JSON;
    deflate => sub {
        my ($data, $tablename, $db) = @_;
        if (defined $data->{json}) {
            $data->{json} = encode_json($data->{json});
        }
        delete $data->{table};
        $data;
    },

You may specify column deflation logic.

Specified code is called internally when called insert(), update(), and delete().

C<$db> is Otogiri instance, you can use Otogiri's method in deflate logic.

=head1 METHODS

=head2 new

    my $db = DBIx::Otogiri->new( connect_info => [$dsn, $dbuser, $dbpass] );

Instantiate and connect to db.

Please see ATTRIBUTE section.

=head2 insert / fast_insert

    my $is_success = $db->insert($table_name => $columns_in_hashref);

Insert a data simply.

=head2 search

=head2 select / search

    ### receive rows of result in array
    my @rows = $db->search($table_name => $conditions_in_hashref [,@options]);
    
    ### or we can receive result as iterator object
    my $iter = $db->search($table_name => $conditions_in_hashref [,@options]);
    
    while (my $row = $iter->next) {
        ... any logic you want ...
    }
    
    printf "rows = %s\n", $iter->fetched_count;

Select from specified table. When you receive result by array, it returns matched rows. Or not, it returns a result as L<DBIx::Otogiri::Iterator> object.

=head2 single / fetch

    my $row = $db->fetch($table_name => $conditions_in_hashref [,@options]);

Select from specified table. Then, returns first of matched rows.

=head2 search_by_sql

    my @rows = $db->search_by_sql($sql, \@bind_vals [, $table_name]);

Select by specified SQL. Then, returns matched rows as array. $table_name is optional and used for inflate parameter.

=head2 update

    $db->update($table_name => [update_col_1 => $new_value_1, ...], $conditions_in_hashref);

Update rows that matched to $conditions_in_hashref.

=head2 delete

    $db->delete($table_name => $conditions_in_hashref);

Delete rows that matched to $conditions_in_hashref.

=head2 do

    $db->do($sql, @bind_vals);

Execute specified SQL.

=head2 txn_scope 

    my $txn = $db->txn_scope;

returns DBIx::TransactionManager::ScopeGuard's instance. See L<DBIx::TransactionManager> to more information.

=head2 last_insert_id 

    my $id = $db->last_insert_id([@args]);

returns last_insert_id. (mysql_insertid in MySQL or last_insert_rowid in SQLite)


=head1 LICENSE

Copyright (C) ytnobody.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

ytnobody E<lt>ytnobody@gmail.comE<gt>

=head1 SEE ALSO

L<DBIx::Sunny>

L<SQL::Maker>

L<DBIx::Otogiri::Iterator>

=cut

