package MusicBrainz::Server::ControllerBase::WS::2;
use Moose;
BEGIN { extends 'Catalyst::Controller'; }

use DBDefs;
use HTTP::Status qw( :constants );
use List::UtilsBy qw( uniq_by );
use MusicBrainz::Server::Data::Utils qw( type_to_model model_to_type object_to_ids );
use MusicBrainz::Server::Validation qw( is_guid is_nat );
use MusicBrainz::Server::WebService::Format;
use MusicBrainz::Server::WebService::JSONSerializer;
use MusicBrainz::Server::WebService::XMLSerializer;
use Readonly;
use Scalar::Util qw( looks_like_number );
use List::UtilsBy qw( partition_by );
use Try::Tiny;

with 'MusicBrainz::Server::WebService::Format' =>
{
    serializers => [
        'MusicBrainz::Server::WebService::XMLSerializer',
        'MusicBrainz::Server::WebService::JSONSerializer',
    ]
};

with 'MusicBrainz::Server::Controller::Role::Profile' => {
    threshold => DBDefs->PROFILE_WEB_SERVICE()
};

with 'MusicBrainz::Server::Controller::Role::CORS';
with 'MusicBrainz::Server::Controller::Role::ETags';

sub apply_rate_limit
{
    my ($self, $c, $key) = @_;
    $key ||= "ws ip=" . $c->request->address;

    my $r;

    $r = $c->model('RateLimiter')->check_rate_limit('ws ua=' . ($c->req->user_agent || ''));
    if ($r && $r->is_over_limit) {
        $c->response->status(HTTP_SERVICE_UNAVAILABLE);
        $c->res->headers->header(
            'X-Rate-Limited' => sprintf('%.1f %.1f %d', $r->rate, $r->limit, $r->period)
        );
        $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
        $c->res->body(
            $c->stash->{serializer}->output_error(
                "Your requests are being throttled by MusicBrainz because the ".
                "application you are using has not identified itself.  Please ".
                "update your application, and see ".
                "http://musicbrainz.org/doc/XML_Web_Service/Rate_Limiting for more ".
                "information."
            )
        );
        $c->detach;
    }

    $r = $c->model('RateLimiter')->check_rate_limit($key);
    if ($r && $r->is_over_limit) {
        $c->response->status(HTTP_SERVICE_UNAVAILABLE);
        $c->res->headers->header(
            'X-Rate-Limited' => sprintf('%.1f %.1f %d', $r->rate, $r->limit, $r->period)
        );
        $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
        $c->res->body(
            $c->stash->{serializer}->output_error(
                "Your requests are exceeding the allowable rate limit (" . $r->msg . "). " .
                    "Please see http://wiki.musicbrainz.org/XMLWebService for more information."
                )
        );
        $c->detach;
    }

    $r = $c->model('RateLimiter')->check_rate_limit('ws global');
    if ($r && $r->is_over_limit) {
        $c->response->status(HTTP_SERVICE_UNAVAILABLE);
        $c->res->headers->header(
            'X-Rate-Limited' => sprintf('%.1f %.1f %d', $r->rate, $r->limit, $r->period)
        );
        $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
        $c->res->body(
            $c->stash->{serializer}->output_error(
                "The MusicBrainz web server is currently busy. " .
                    "Please try again later."
                )
        );
        $c->detach;
    }
}

sub bad_req : Private
{
    my ($self, $c) = @_;

    $c->res->status(400);
    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body($c->stash->{serializer}->output_error($c->stash->{error}));
}

sub deny_readonly : Private
{
    my ($self, $c) = @_;
    if (DBDefs->DB_READ_ONLY) {
        $c->res->status(503);
        $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
        $c->res->body($c->stash->{serializer}->output_error("The database is currently in readonly mode and cannot handle your request"));
        $c->detach;
    }
}

sub success : Private
{
    my ($self, $c) = @_;
    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body($c->stash->{serializer}->output_success);
}

sub forbidden : Private
{
    my ($self, $c) = @_;
    $c->res->status(401);
    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body($c->stash->{serializer}->output_error("You are not authorized to access this resource."));
}

sub unauthorized : Private
{
    my ($self, $c) = @_;
    $c->res->status(401);
    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body($c->stash->{serializer}->output_error("Your credentials ".
        "could not be verified.\nEither you supplied the wrong credentials ".
        "(e.g., bad password), or your client doesn't understand how to ".
        "supply the credentials required."));
}

sub not_found : Private
{
    my ($self, $c) = @_;
    $c->res->status(404);
    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body($c->stash->{serializer}->output_error("Not Found"));
}

sub invalid_mbid : Private
{
    my ($self, $c, $id) = @_;
    $c->stash->{error} = "Invalid mbid.";
    $c->detach('bad_req');
}

sub begin : Private { }
sub end : Private { }

sub root : Chained('/') PathPart("ws/2") CaptureArgs(0)
{
    my ($self, $c) = @_;

    try {
        $self->validate($c) or $c->detach('bad_req');
    }
    catch {
        my $err = $_;
        if (eval { $err->isa('MusicBrainz::Server::WebService::Exceptions::UnknownIncParameter') }) {
            $self->_error($c, $err->message);
        }
        $c->detach;
    };

    $self->apply_rate_limit($c);
    $self->authenticate($c, $c->stash->{authorization_scope})
        if ($c->stash->{authorization_required});
}

sub authenticate
{
    my ($self, $c, $scope) = @_;

    $c->authenticate({}, 'musicbrainz.org');
    $self->forbidden($c) unless $c->user->is_authorized($scope);
}

sub _error
{
    my ($self, $c, $error) = @_;

    $c->stash->{error} = $error;
    $c->detach('bad_req');
}

sub _search
{
    my ($self, $c, $entity) = @_;

    my $result = $c->model('WebService')->xml_search($entity, $c->stash->{args});
    if (DBDefs->LUCENE_X_ACCEL_REDIRECT && exists $result->{redirect_url}) {
        $c->res->headers->header(
            'X-Accel-Redirect' => $result->{redirect_url}
        );
    } else {
        $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
        if (exists $result->{xml})
        {
            $c->res->body($result->{xml});
        }
        else
        {
            $c->res->status($result->{code});
            $c->res->body($c->stash->{serializer}->output_error($result->{error}));
        }
    }
}

sub _tags_and_ratings
{
    my $self = shift;
    $self->_tags(@_);
    $self->_ratings(@_);
}

sub _tags
{
    my ($self, $c, $modelname, $entities, $stash) = @_;

    my %map = object_to_ids(@$entities);
    my $model = $c->model($modelname);

    my @todo = grep { $c->stash->{inc}->$_ } qw( tags user_tags );

    for my $type (@todo) {
        my $find_method = 'find_' . $type . '_for_entities';
        my @tags = $model->tags->$find_method(
                        $type eq 'user_tags' ? $c->user->id : (),
                        map { $_->id } @$entities);

        my %tags_by_entity = partition_by { $_->entity_id } @tags;
        for my $id (keys %tags_by_entity) {
            $stash->store($map{$id}->[0])->{$type} = $tags_by_entity{$id};
        }
    }
}

sub _ratings
{
    my ($self, $c, $modelname, $entities, $stash) = @_;

    my %map = object_to_ids(@$entities);
    my $model = $c->model($modelname);

    if ($c->stash->{inc}->ratings)
    {
        $model->load_meta(@$entities);

        for (@$entities)
        {
            if ($_->rating_count)
            {
                $stash->store($_)->{ratings} = {
                    rating => $_->rating * 5 / 100,
                    count => $_->rating_count,
                };
            }
        }
    }

    if ($c->stash->{inc}->user_ratings)
    {
        $model->rating->load_user_ratings($c->user->id, @$entities);
        for (@$entities)
        {
            $stash->store($_)->{user_ratings} = $_->user_rating * 5 / 100
                if $_->user_rating;
        }
    }
}

sub _aliases {
    my ($self, $c, $model, $entities, $stash) = @_;

    if ($c->stash->{inc}->aliases) {
        my @aliases = @{ $c->model($model)->alias->find_by_entity_id(map { $_->id } @$entities) };

        $c->model($model)->alias_type->load(@aliases);

        my $entity_id = model_to_type($model) . '_id';
        my %alias_per_entity;

        for (@aliases) {
            $alias_per_entity{$_->$entity_id} = [] unless $alias_per_entity{$_->$entity_id};
            push @{ $alias_per_entity{$_->$entity_id} }, $_;
        }

        for (@$entities) {
            $stash->store($_)->{aliases} = $alias_per_entity{$_->id};
        }
    }
}

sub _limit_and_offset
{
    my ($self, $c) = @_;

    my $args = $c->stash->{args};
    my $limit = $args->{limit} ? $args->{limit} : 25;
    my $offset = $args->{offset} ? $args->{offset} : 0;

    if (!(is_nat($limit) && is_nat($offset))) {
        $self->_error(
            $c, "The 'limit' and 'offset' parameters must be positive integers"
        );
    }

    return ($limit > 100 ? 100 : $limit, $offset);
}

sub make_list
{
    my ($self, $results, $total, $offset) = @_;

    return {
        items => $results,
        total => defined $total ? $total : scalar @$results,
        offset => defined $offset ? $offset : 0
    };
}

sub linked_artists
{
    my ($self, $c, $stash, $artists) = @_;

    $self->_tags_and_ratings($c, 'Artist', $artists, $stash);
    $self->_aliases($c, 'Artist', $artists, $stash);
}

sub linked_areas
{
    my ($self, $c, $stash, $areas) = @_;

    $self->_tags($c, 'Area', $areas, $stash);
    $self->_aliases($c, 'Area', $areas, $stash);
}

sub linked_instruments
{
    my ($self, $c, $stash, $instruments) = @_;

    $self->_tags($c, 'Instrument', $instruments, $stash);
    $self->_aliases($c, 'Instrument', $instruments, $stash);
}

sub linked_collections
{
    my ($self, $c, $stash, $collections) = @_;
}

sub linked_labels
{
    my ($self, $c, $stash, $labels) = @_;

    $self->_tags_and_ratings($c, 'Label', $labels, $stash);
    $self->_aliases($c, 'Label', $labels, $stash);
}

sub linked_places
{
    my ($self, $c, $stash, $places) = @_;

    $self->_tags_and_ratings($c, 'Place', $places, $stash);
    $self->_aliases($c, 'Place', $places, $stash);
}

sub linked_recordings
{
    my ($self, $c, $stash, $recordings) = @_;

    if ($c->stash->{inc}->isrcs)
    {
        my @isrcs = $c->model('ISRC')->find_by_recordings(map { $_->id } @$recordings);

        my %isrc_per_recording;
        for (@isrcs)
        {
            $isrc_per_recording{$_->recording_id} = [] unless $isrc_per_recording{$_->recording_id};
            push @{ $isrc_per_recording{$_->recording_id} }, $_;
        };

        for (@$recordings)
        {
            $stash->store($_)->{isrcs} = $isrc_per_recording{$_->id};
        }
    }

    if ($c->stash->{inc}->artist_credits)
    {
        $c->model('ArtistCredit')->load(@$recordings);

        my @acns = map { $_->artist_credit->all_names } @$recordings;
        $c->model('Artist')->load(@acns);

        $self->linked_artists(
            $c, $stash,
            [ uniq_by { $_->id } map { $_->artist } @acns ]
        );
    }

    $self->_tags_and_ratings($c, 'Recording', $recordings, $stash);
    $self->_aliases($c, 'Recording', $recordings, $stash);
}

sub linked_releases
{
    my ($self, $c, $stash, $releases) = @_;

    $c->model('ReleaseStatus')->load(@$releases);
    $c->model('ReleasePackaging')->load(@$releases);
    $c->model('Release')->load_release_events(@$releases);

    $c->model('Language')->load(@$releases);
    $c->model('Script')->load(@$releases);
    $c->model('Release')->load_release_events(@$releases);

    my @mediums;
    if ($c->stash->{inc}->media || $c->stash->{inc}->recordings)
    {
        @mediums = map { $_->all_mediums } @$releases;

        unless (@mediums)
        {
            $c->model('Medium')->load_for_releases(@$releases);
            @mediums = map { $_->all_mediums } @$releases;
        }

        $c->model('MediumFormat')->load(@mediums);
    }

    if ($c->stash->{inc}->discids)
    {
        my @medium_cdtocs = $c->model('MediumCDTOC')->load_for_mediums(@mediums);
        $c->model('CDTOC')->load(@medium_cdtocs);
    }

    if ($c->stash->{inc}->artist_credits)
    {
        $c->model('ArtistCredit')->load(@$releases);
    }

    $self->_tags($c, 'Release', $releases, $stash);
    $self->_aliases($c, 'Release', $releases, $stash);
}

sub linked_release_groups
{
    my ($self, $c, $stash, $release_groups) = @_;

    $c->model('ReleaseGroupType')->load(@$release_groups);

    if ($c->stash->{inc}->artist_credits)
    {
        $c->model('ArtistCredit')->load(@$release_groups);
    }

    $self->_tags_and_ratings($c, 'ReleaseGroup', $release_groups, $stash);
    $self->_aliases($c, 'ReleaseGroup', $release_groups, $stash);
}

sub linked_works
{
    my ($self, $c, $stash, $works) = @_;

    $c->model('ISWC')->load_for_works(@$works);

    $self->_tags_and_ratings($c, 'Work', $works, $stash);
    $self->_aliases($c, 'Work', $works, $stash);
}

sub linked_series {
    my ($self, $c, $stash, $series) = @_;

    $self->_tags($c, 'Series', $series, $stash);
    $self->_aliases($c, 'Series', $series, $stash);
}

sub linked_events
{
    my ($self, $c, $stash, $events) = @_;

    $self->_tags_and_ratings($c, 'Event', $events, $stash);
    $self->_aliases($c, 'Event', $events, $stash);
}

sub _validate_post
{
    my ($self, $c) = @_;

    my $h = $c->request->headers;

    unless ($h->content_type eq 'application/xml' &&
            $h->content_type_charset eq 'UTF-8') {
        $c->stash->{error} = '/ws/2/ only supports POST in application/xml; charset=UTF-8';
        $c->forward('bad_req');
        $c->res->status(415);
        $c->detach;
    }

    $self->_error($c, "Please specify the name and version number of your client application.")
        unless $c->req->params->{client};
}

sub _validate_entity
{
    my ($self, $c) = @_;

    my $gid = $c->stash->{args}->{id};
    my $entity = $c->stash->{args}->{entity};
    $entity =~ s/-/_/;

    my $model = type_to_model($entity);

    if (!$gid || !is_guid($gid))
    {
        $c->stash->{error} = "Invalid mbid.";
        $c->detach('bad_req');
    }

    if (!$model)
    {
        $c->stash->{error} = "Invalid entity type.";
        $c->detach('bad_req');
    }

    $entity = $c->model($model)->get_by_gid($gid);
    $c->detach('not_found') unless ($entity);

    return ($entity, $model);
}

sub load_relationships {
    my ($self, $c, $stash, @for) = @_;

    if ($c->stash->{inc}->has_rels)
    {
        my $types = $c->stash->{inc}->get_rel_types();
        my @rels = $c->model('Relationship')->load_subset($types, @for);

        my @works =
            map { $_->target }
            grep { $_->target_type eq 'work' }
            map { $_->all_relationships } @for;

        if ($c->stash->{inc}->work_level_rels)
        {
            $c->model('Relationship')->load_subset($types, @works);
        }
        $self->linked_works($c, $stash, \@works);

        my $collect_works = sub {
            my $relationship = shift;
            return (
                ($relationship->target_type eq 'work' && $relationship->target) || (),
                ($relationship->source_type eq 'work' && $relationship->source) || (),
            );
        };

        my @releases = map { $_->target } grep { $_->target_type eq 'release' }
            map { $_->all_relationships } @for;

        my @load_language_for = (
            @releases,
            map { $collect_works->($_) } (@rels, map { $_->all_relationships } @works)
        );

        $c->model('Language')->load(@load_language_for);
        $c->model('Script')->load(@releases);
        $c->model('Release')->load_release_events(@releases);
    }
}

no Moose;
1;

=head1 COPYRIGHT

Copyright (C) 2010 MetaBrainz Foundation
Copyright (C) 2009 Lukas Lalinsky
Copyright (C) 2009 Robert Kaye

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
