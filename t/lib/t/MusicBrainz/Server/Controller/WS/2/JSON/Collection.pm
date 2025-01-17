package t::MusicBrainz::Server::Controller::WS::2::JSON::Collection;
use utf8;
use JSON;
use Test::Routine;
use Test::More;
use MusicBrainz::Server::Test qw( html_ok );
use MusicBrainz::Server::Test ws_test_json => {
    version => 2
};

with 't::Mechanize', 't::Context';

test "collection lookup" => sub {
    my $test = shift;
    my $c = $test->c;

    MusicBrainz::Server::Test->prepare_test_database($c, '+webservice');
    MusicBrainz::Server::Test->prepare_test_database($c, <<'EOSQL');
INSERT INTO editor (id, name, password, ha1) VALUES (1, 'new_editor', '{CLEARTEXT}password', 'e1dd8fee8ee728b0ddc8027d3a3db478');
INSERT INTO editor_collection (id, gid, editor, name, public, type)
    VALUES (1, 'f34c079d-374e-4436-9448-da92dedef3ce', 1, 'my collection', FALSE, 1);
INSERT INTO editor_collection_release (collection, release) VALUES (1, 123054);
EOSQL

    ws_test_json 'collections lookup',
        '/collection/f34c079d-374e-4436-9448-da92dedef3ce' => {
            collections => [
                {
                    id => "f34c079d-374e-4436-9448-da92dedef3ce",
                    name => "my collection",
                    editor => "new_editor",
                    type => "Release",
                    "entity-type" => "release",
                    "release-count" => 1,
                }
            ]
        }, { username => 'new_editor', password => 'password' };

    ws_test_json 'collection releases lookup',
        '/collection/f34c079d-374e-4436-9448-da92dedef3ce/releases/' =>
            {
                id => "f34c079d-374e-4436-9448-da92dedef3ce",
                name => "my collection",
                editor => "new_editor",
                type => "Release",
                "entity-type" => "release",
                "release-count" => 1,
                releases => [
                    {
                        id => "b3b7e934-445b-4c68-a097-730c6a6d47e6",
                        title => "Summer Reggae! Rainbow",
                        status => "Pseudo-Release",
                        quality => "normal",
                        "text-representation" => {
                            language => "jpn",
                            script => "Latn",
                        },
                        date => "2001-07-04",
                        country => "JP",
                        "release-events" => [{
                            date => "2001-07-04",
                            "area" => {
                                disambiguation => '',
                                "id" => "2db42837-c832-3c27-b4a3-08198f75693c",
                                "name" => "Japan",
                                "sort-name" => "Japan",
                                "iso-3166-1-codes" => ["JP"],
                            },
                        }],
                        barcode => "4942463511227",
                        disambiguation => "",
                        packaging => JSON::null,
                    }]
            }, { username => 'new_editor', password => 'password' };
};

1;
