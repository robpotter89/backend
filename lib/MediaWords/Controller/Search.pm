package MediaWords::Controller::Search;

use Modern::Perl "2013";
use MediaWords::CommonLibs;

use strict;
use warnings;
use base 'Catalyst::Controller';

use MediaWords::Solr;
use MediaWords::Util::CSV;
use MediaWords::ActionRole::Logged;

=head1 NAME>

MediaWords::Controller::Health - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller for basic story search page

=cut

__PACKAGE__->config(    #
    action => {         #
        index => { Does => [ qw( ~Throttled ~Logged ) ] },    #
        wc    => { Does => [ qw( ~Throttled ~Logged ) ] },    #
      }    #
);         #

# number of stories to sample for the search
use constant NUM_SAMPLED_STORIES => 100;

# get tag_sets_id for collection: tag set
sub _get_collection_tag_sets_id
{
    my ( $db ) = @_;

    my $tag_set = $db->query( "select * from tag_sets where name = 'collection'" )->hash
      || die( "Unable to find 'collection' tag set" );

    return $tag_set->{ tag_sets_id };
}

# list all collection tags, with media set names attached
sub tags : Local
{
    my ( $self, $c, $tag_sets_id ) = @_;

    my $db = $c->dbis;

    $tag_sets_id //= _get_collection_tag_sets_id( $db );

    my $tag_set = $db->find_by_id( 'tag_sets', $tag_sets_id ) || die( "Unable to find tag_set '$tag_sets_id'" );

    my $tags = $db->query( <<END, $tag_sets_id )->hashes;
with set_tags as (
    
    select t.* from tags t 
        where tag_sets_id = ? and
            tags_id not in ( select tags_id from media_sets where include_in_dump = false )
            
)
        
select t.*, ms.media_set_names, mtm.media_count
    from set_tags t
    
        left join ( 
            select count(*) media_count, mtm.tags_id 
                from media_tags_map mtm
                group by mtm.tags_id
        ) mtm on ( mtm.tags_id = t.tags_id )
        
        left join (
            select ms.tags_id,
                array_to_string( array_agg( d.name || ':' || ms.name ), '; ' ) media_set_names
            from media_sets ms
                join dashboard_media_sets dms on ( dms.media_sets_id = ms.media_sets_id )
                join dashboards d on ( d.dashboards_id = dms.dashboards_id ) 
            where ms.tags_id is not null
            group by ms.tags_id
        ) ms on ( t.tags_id = ms.tags_id )

    order by media_set_names, t.tags_id
END

    $c->stash->{ tags }     = $tags;
    $c->stash->{ tag_set }  = $tag_set;
    $c->stash->{ template } = 'search/tags.tt2';
}

# list all media sources associated with the given tag
sub media : Local
{
    my ( $self, $c, $tags_id ) = @_;

    die( "no tags_id" ) unless ( $tags_id );

    my $db = $c->dbis;

    my $tag = $db->find_by_id( 'tags', $tags_id );

    my $media = $db->query( <<'END', $tags_id )->hashes;
select m.* 
    from media m join media_tags_map mtm on ( m.media_id = mtm.media_id )
    where mtm.tags_id = ?
    order by mtm.media_id
END

    $c->stash->{ media }    = $media;
    $c->stash->{ tag }      = $tag;
    $c->stash->{ template } = 'search/media.tt2';
}

# given a list of stories, generate a list of all tags with show_on_media or show_on_stories true.
# attach a comma separated list of the tags associated with each story to the story and return
# a list of story counts for each tag sorted by descending count in the following format:
# [ [ tag_name => $a, tags_id => $b, count => $c ], ... ]
sub _generate_story_tag_data
{
    my ( $db, $stories ) = @_;

    $db->begin;

    my $ids_table = $db->get_temporary_ids_table( [ map { $_->{ stories_id } } @{ $stories } ] );

    my $story_tags = $db->query( <<END )->hashes;
select distinct stm.stories_id, t.description,
        t.tags_id, coalesce( ts.label, ts.name ) || ' - ' || coalesce( t.label, t.tag ) tag_name
    from stories_tags_map stm
        join tags t on ( stm.tags_id = t.tags_id )
        join tag_sets ts on ( t.tag_sets_id = ts.tag_sets_id )
    where 
        stm.stories_id in ( select id from $ids_table ) and
        ( t.show_on_media or t.show_on_stories or ts.show_on_media or ts.show_on_stories )
    
union
    
select distinct s.stories_id, t.description,
        t.tags_id, coalesce( ts.label, ts.name ) || ' - ' || coalesce( t.label, t.tag ) tag_name
    from stories s
        join media_tags_map mtm on ( s.media_id = mtm.media_id )
        join tags t on ( mtm.tags_id = t.tags_id )
        join tag_sets ts on ( t.tag_sets_id = ts.tag_sets_id )
    where 
        s.stories_id in ( select id from $ids_table ) and
        ( t.show_on_media or t.show_on_stories or ts.show_on_media or ts.show_on_stories )

END

    $db->commit;

    my $story_tag_names  = {};
    my $story_tag_counts = {};
    for my $story_tag ( @{ $story_tags } )
    {
        push( @{ $story_tag_names->{ $story_tag->{ stories_id } } }, $story_tag->{ tag_name } );

        $story_tag_counts->{ $story_tag->{ tags_id } } //= $story_tag;
        $story_tag_counts->{ $story_tag->{ tags_id } }->{ count }++;
    }

    my $aggregate_story_tags =
      [ map { { stories_id => $_, tag_names => join( "; ", @{ $story_tag_names->{ $_ } } ) } }
          keys( %{ $story_tag_names } ) ];
    MediaWords::DBI::Stories::attach_story_data_to_stories( $stories, $aggregate_story_tags );

    return [ sort { $b->{ count } <=> $a->{ count } } values( %{ $story_tag_counts } ) ];
}

# search for stories using solr and return either a sampled list of stories in html or the full list in csv
sub index : Path : Args(0)
{
    my ( $self, $c ) = @_;

    my $q = $c->req->params->{ q } || '';
    my $l = $c->req->params->{ l };

    if ( !$q )
    {
        $c->stash->{ template } = 'search/search.tt2';
        $c->stash->{ title }    = 'Search';
        return;
    }

    my $db = $c->dbis;

    my $csv = $c->req->params->{ csv };

    my $solr_params = { q => $q };
    if ( $csv )
    {
        $solr_params->{ rows } = 100_000;
    }
    else
    {
        $solr_params->{ sort } = 'random_1 asc';
        $solr_params->{ rows } = NUM_SAMPLED_STORIES;
    }

    my $stories;
    eval { $stories = MediaWords::Solr::search_for_stories( $db, $solr_params ) };

    my $tag_counts = _generate_story_tag_data( $db, $stories );

    my $num_stories;
    if ( @{ $stories } < NUM_SAMPLED_STORIES )
    {
        $num_stories = @{ $stories };
    }
    else
    {
        $num_stories = int( MediaWords::Solr::get_last_num_found() / MediaWords::Solr::get_last_sentences_per_story() );
    }

    if ( $@ =~ /solr.*Bad Request/ )
    {
        $c->stash->{ status_msg } = 'Cannot parse search query';
        $c->stash->{ q }          = $q;
        $c->stash->{ l }          = $l;
        $c->stash->{ template }   = 'search/search.tt2';
    }
    elsif ( $@ )
    {
        die( $@ );
    }
    elsif ( $csv )
    {
        map { delete( $_->{ sentences } ) } @{ $stories };
        my $encoded_csv = MediaWords::Util::CSV::get_hashes_as_encoded_csv( $stories );

        $c->response->header( "Content-Disposition" => "attachment;filename=stories.csv" );
        $c->response->content_type( 'text/csv; charset=UTF-8' );
        $c->response->content_length( bytes::length( $encoded_csv ) );
        $c->response->body( $encoded_csv );

        MediaWords::ActionRole::Logged::set_requested_items_count( $c, $num_stories + 1 )
          ;    # number of stories + the request itself
    }
    else
    {
        $c->stash->{ stories }     = $stories;
        $c->stash->{ num_stories } = $num_stories;
        $c->stash->{ tag_counts }  = $tag_counts;
        $c->stash->{ l }           = $l;
        $c->stash->{ q }           = $q;
        $c->stash->{ template }    = 'search/search.tt2';
    }
}

# print word cloud of search results
sub wc : Local
{
    my ( $self, $c ) = @_;

    my $q = $c->req->params->{ q };
    my $l = $c->req->params->{ l } || '';

    if ( !$q )
    {
        $c->stash->{ template } = 'search/wc.tt2';
        return;
    }

    my $languages = [ split( /\W/, $l ) ];

    if ( $q =~ /story_sentences_id|sentence_number/ )
    {
        die( "searches by sentence not allowed" );
    }

    die( "missing q" ) unless ( $q );

    my $words;
    eval { $words = MediaWords::Solr::count_words( $q, undef, $languages ) };

    if ( $@ =~ /solr.*Bad Request/ )
    {
        $c->stash->{ status_msg } = 'Cannot parse search query';
        $c->stash->{ q }          = $q;
        $c->stash->{ l }          = $l;
        $c->stash->{ template }   = 'search/wc.tt2';
    }
    elsif ( $@ )
    {
        die( $@ );
    }
    elsif ( $c->req->params->{ csv } )
    {
        my $encoded_csv = MediaWords::Util::CSV::get_hashes_as_encoded_csv( $words );

        $c->response->header( "Content-Disposition" => "attachment;filename=words.csv" );
        $c->response->content_type( 'text/csv; charset=UTF-8' );
        $c->response->content_length( bytes::length( $encoded_csv ) );
        $c->response->body( $encoded_csv );
    }
    else
    {
        $c->stash->{ words }    = $words;
        $c->stash->{ q }        = $q;
        $c->stash->{ l }        = $l;
        $c->stash->{ template } = 'search/wc.tt2';
    }
}

# print out search instructions
sub readme : Local
{
    my ( $self, $c ) = @_;

    $c->stash->{ template } = 'search/readme.tt2';
}

# list tag sets
sub tag_sets : Local
{
    my ( $self, $c ) = @_;

    my $db = $c->dbis;

    my $tag_sets = $db->query( <<END )->hashes;
select ts.*
    from tag_sets ts
    where 
        exists ( 
            select 1 
                from media_tags_map mtm 
                    join tags t on ( mtm.tags_id = t.tags_id )
                where t.tag_sets_id = ts.tag_sets_id
        )
    order by name
END

    $c->stash->{ tag_sets } = $tag_sets;
    $c->stash->{ template } = 'search/tag_sets.tt2';
}

1;
