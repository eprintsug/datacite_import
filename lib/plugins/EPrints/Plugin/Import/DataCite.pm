=head1 NAME

EPrints::Plugin::Import::DataCite

=cut

package EPrints::Plugin::Import::DataCite;

# 10.1002/asi.20373

use strict;

use EPrints::Plugin::Import::TextFile;
use JSON;
use LWP::Simple qw(get);
use URI;
use Encode;

our @ISA = qw/ EPrints::Plugin::Import::TextFile /;

sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new( %params );

	$self->{name} = "DOI (via DataCite)";
	$self->{visible} = "all";
	$self->{produce} = [ 'dataobj/eprint', 'list/eprint' ];
	$self->{screen} = "Import::DataCite";

	$self->{ base_url } = "https://api.datacite.org/dois/";

	return $self;
}

sub screen
{
	my( $self, %params ) = @_;
	return $self->{repository}->plugin( "Screen::Import::DataCite", %params );
}

sub input_text_fh
{
	my( $plugin, %opts ) = @_;

	my @ids;

	my $session = $plugin->{repository};
	my $use_prefix = $plugin->param( "use_prefix" ) || 1;
	my $doi_field = $plugin->param( "doi_field" ) || 'id_number';

	my $fh = $opts{fh};
	while( my $doi = <$fh> )
	{
		$doi =~ s/^\s+//;
		$doi =~ s/\s+$//;

		next unless length($doi);
		my $obj = EPrints::DOI->parse( $doi );
		if( $obj )
		{
			$doi = $obj->to_string( noprefix => !$use_prefix );
		}

		#some doi's in the repository may have the "doi:" prefix and others may not, so we need to check both cases - rwf1v07:27/01/2016
		my $doi2 = $doi;
		$doi =~ s/^(doi:)?//i;
		$doi2 =~ s/^(doi:)?/doi:/i;

		# START check and exclude DOI from fetch if DOI already exists in the 'archive' dataset - Alan Stiles, Open University, 20140408
		my $duplicates = $session->dataset( 'archive' )->search(
						filters =>
						[
							{ meta_fields => [$doi_field], value => "$doi $doi2", match => "EQ", merge => "ANY" }, #check for both "doi:" prefixed values and ones which aren't prefixed - rwf1v07:27/01/2016
						]
		);
		if ( $duplicates->count() > 0 )
		{
			$plugin->handler->message( "warning", $plugin->html_phrase( "duplicate_doi",
				doi => $plugin->{session}->make_text( $doi ),
				msg => $duplicates->item( 0 )->render_citation_link(),
			));
			next;
		}
		# END check and exclude DOI from fetch if DOI already exists in the 'archive' dataset - Alan Stiles, Open University, 20140408
	
		my $url = URI->new( $plugin->{ base_url } . $doi );

		my $attributes;
		eval { 
			my $res = LWP::Simple::get( $url );
			my $json = JSON->new->utf8->decode( $res );
			$attributes = $json->{data}->{attributes};
		};

		if( $@ || !defined $attributes)
		{
			$plugin->handler->message( "warning", $plugin->html_phrase( "invalid_doi",
				doi => $plugin->{session}->make_text( $doi ),
				status => $plugin->{session}->make_text( "No or unrecognised response" )
			));
			next;
		}

		my $data = { doi => $doi };
		my $types_map = $plugin->{session}->config('datacite_import', 'typemap' );
		my $type = $attributes->{types}->{resourceTypeGeneral};
		my $subtype = $attributes->{types}->{resourceType};

		$data->{type} = $types_map->{$type};

		foreach my $name ( keys $attributes ) 
		{
			if( $name eq "contributors" || $name eq "creators" )
            {  
                $plugin->contributors( $data, $attributes->{$name} );
            }
			elsif ( $name eq "dates" )
            {
                $plugin->dates( $data, $attributes->{$name} );
            }
			elsif ( $name eq "descripions" )
            {
                $plugin->descriptions( $data, $attributes->{$name} );
            }
			elsif ( $name eq "identifiers" )
			{
				$plugin->identifiers( $data, $attributes->{$name} );
			}
			elsif ( $name eq "publisher" )
			{
				$data->{publisher} = $attributes->{$name};
			}
			elsif( $name eq "relatedItems" )
			{
				$plugin->related_items( $data, $attributes->{$name} );
			}
			elsif ( $name eq "titles" )
			{
				$plugin->titles( $data, $attributes->{$name} );
			}

		}

		use Data::Dumper;
		open(FH, '>', "/tmp/datacite_import.log" ) or die $!;
		print FH "data: ".Dumper( $data ) ."\n\n";
		my $epdata = $plugin->convert_input( $data );
		print FH "epdata: ".Dumper( $epdata ) ."\n\n";		

		next unless( defined $epdata );

		my $dataobj = $plugin->epdata_to_dataobj( $opts{dataset}, $epdata );
		if( defined $dataobj )
		{
			push @ids, $dataobj->get_id;
		}
	}

	return EPrints::List->new( 
		dataset => $opts{dataset}, 
		session => $plugin->{session},
		ids=>\@ids );
}

sub contributors
{
	my( $plugin, $data, $attribute ) = @_;

	my @creators = defined $data->{creators} ? @{$data->{creators}} : ();
	my @corp_creators = defined $data->{corp_creators} ? @{$data->{corp_creators}} : ();
	my @editors = defined $data->{editors} ? @{$data->{editors}} : ();
	my @contributors = defined $data->{contributors} ? @{$data->{contributors}} : ();

	foreach my $contributor ( @$attribute )
	{
		my $role = "author";
		my $person_name = {};
		my $orcid = undef;

		foreach my $part (keys $contributor)
		{
			if( $part eq "contributorType" )
			{
				$role = lc($contributor->{$part});
			}
			elsif( $part eq "givenName" )
			{
				$person_name->{given} = $contributor->{$part};
			}
			elsif( $part eq "familyName" )
			{
				$person_name->{family} = $contributor->{$part};
			}
			elsif ( $part eq "name" )
			{
				$person_name->{name} = $contributor->{$part};
			}	
			elsif( $part eq "nameIdentifiers" )
			{
				foreach my $ni ( @{$contributor->{$part}} )
				{
					if ( $ni->{nameIdentifierScheme} eq "ORCID" )
					{
						$orcid = $ni->{nameIdentifier};
						$orcid =~ s!https?://orcid.org/!!;
						last;
					}
				}
			}
		}
		delete $person_name->{name} if EPrints::Utils::is_set( $person_name->{family} );

		if ( exists $person_name->{family} )
		{
			if ( $role eq "author" )
			{
				push @creators, { name => $person_name, orcid => $orcid };
			}
			elsif ( $role eq "editor" )
			{
				push @editors, { name => $person_name, orcid => $orcid };
			}
			else
			{
				my %contributor_types = (
					"author" => "http://www.loc.gov/loc.terms/relators/AUT",
					"editor" => "http://www.loc.gov/loc.terms/relators/EDT",
					"chair" => "http://www.loc.gov/loc.terms/relators/EDT",
					"reviewer" => "http://www.loc.gov/loc.terms/relators/REV",
					"reviewer-assistant" => "http://www.loc.gov/loc.terms/relators/REV",
					"stats-reviewer" => "http://www.loc.gov/loc.terms/relators/REV",
					"reviewer-external" => "http://www.loc.gov/loc.terms/relators/REV",
					"reader" => "http://www.loc.gov/loc.terms/relators/OTH",
					"translator" => "http://www.loc.gov/loc.terms/relators/TRL",
				);
				push @contributors, { name => $person_name, type => $contributor_types{$role} , orcid => $orcid };
			}
		}
		elsif ( defined $person_name->{name} && $role eq "author" )
                {
	               push @corp_creators, $person_name->{name};
                }

	}

	$data->{creators} = \@creators if @creators;
	$data->{corp_creators} = \@corp_creators if @corp_creators;
	$data->{editors} = \@editors if @editors;
	$data->{contributors} = \@contributors if @contributors;
}

sub identifiers
{
	my( $plugin, $data, $attribute ) = @_;

    foreach my $id ( @$attribute )
    {
		if ( $id->{identifierType} eq 'URL' )
		{
			$data->{official_url} = $id->{identifier};
		}
    }
}

sub descriptions
{
    my( $plugin, $data, $attribute ) = @_;

    foreach my $desc ( @$attribute )
    {
        if ( $desc->{descriptionType} eq 'Abstract' )
        {
            $data->{abstract} = $desc->{description};
        }
    }
}

sub dates
{
    my( $plugin, $data, $attribute ) = @_;

	my $dates = {};
	my $datemap = $plugin->{session}->config( 'datacite_import', 'datemap' );
    foreach my $date ( @$attribute )
    {
        if ( defined $datemap->{$date->{dateType}} )
        {	
        	$dates->{$datemap->{$date->{dateType}}} = $date->{date};
       	}
	}
	$data->{dates} = $dates;
}

sub related_items
{
    my( $plugin, $data, $attribute ) = @_;

    foreach my $related ( @$attribute )
    {
		if ( $related->{relationType} eq 'IsPublishedIn' && $related->{relatedItemType} eq 'Journal' )
		{
			$data->{journal_title} = $related->{titles}->[0]->{title} if EPrints::Utils::is_set( $related->{titles}->[0] );
			$data->{volume} = $related->{volume};
			$data->{issue} = $related->{issue};
			$data->{first_page} = $related->{firstPage};
			$data->{last_page} = $related->{lastPage};
		}
    }
}

sub titles
{
    my( $plugin, $data, $attribute ) = @_;

	$data->{title} = $attribute->[0]->{title};
}


sub convert_input
{
	my( $plugin, $data ) = @_;

	my $epdata = {};
	my $use_prefix = $plugin->param( "use_prefix" ) || 1;
	my $doi_field = $plugin->param( "doi_field" ) || "id_number";

	if( defined $data->{creators} )
	{
		$epdata->{creators} = $data->{creators};
	}
	elsif( defined $data->{author} )
	{
		$epdata->{creators} = [ 
			{ 
				name=>{ family=>$data->{author} }, 
			} 
		];
	}

	if( defined $data->{corp_creators} )
	{
		$epdata->{corp_creators} = $data->{corp_creators};
	}
	if( defined $data->{editors} )
	{
		$epdata->{editors} = $data->{editors};
	}
	if( defined $data->{contributors} )
	{
		$epdata->{contributors} = $data->{contributors};
	}

	if( defined $data->{dates} )
	{	
		my $eprint_ds = $plugin->{session}->dataset( 'eprint' );
        if ( $eprint_ds->has_field( 'dates' ) )
       	{
           	$epdata->{dates} = $data->{dates};
			foreach my $date ( @{$epdata->{dates}} )
			{
				if ( $date->{date_type} eq "published" || $date->{date_type} eq "published_online" ) 
				{
					$epdata->{ispublished} = "pub".
					last;
				}
				elsif ( $date->{date_type} eq "submitted" )
				{
					$epdata->{ispublished} = "submitted";
				}
			}
       	}
      	else
       	{
           	my $priority = $plugin->{session}->config( 'datacite_import', 'date_priority' );
			foreach my $p ( @$priority )
			{
				if ( defined $data->{dates}->{$p} )
				{
					$epdata->{date} = $data->{dates}->{$p};
					$epdata->{date_type} = $p;
					last;
				}
			}
			$epdata->{date_type} = "published" if $epdata->{date_type} eq "published_online";
			$epdata->{ispublished} = "pub" if defined $epdata->{date_type} && $epdata->{date_type} eq "published";
			$epdata->{ispublished} = "submitted" if defined $epdata->{date_type} && $epdata->{date_type} eq "submitted";
		}
	}
		
	if( defined $data->{publisher} )
        {
		  $epdata->{publisher} = $data->{publisher};
	}

	if( defined $data->{"issn.electronic"} )
	{
		$epdata->{issn} = $data->{"issn.electronic"};
	}
	if( defined $data->{"issn.print"} )
	{
		$epdata->{issn} = $data->{"issn.print"};
	}
	if( defined $data->{"isbn.electronic"} )
	{
		$epdata->{isbn} = $data->{"isbn.electronic"};
	}
	if( defined $data->{"isbn"} )
	{
		$epdata->{isbn} = $data->{"isbn"};
	}
	if( defined $data->{"issn.print"} )
	{
		$epdata->{isbn} = $data->{"isbn.print"};
	}

	if( defined $data->{"doi"} )
	{
		#Use doi field identified from config parameter, in case it has been customised. Alan Stiles, Open University 20140408
		my $doi = EPrints::DOI->parse( $data->{"doi"} );
	if( $doi )
	{
		$epdata->{$doi_field} = $doi->to_string( noprefix=>!$use_prefix );
		$epdata->{official_url} = $doi->to_uri->as_string;
	}
	else
	{
		$epdata->{$doi_field} = $data->{"doi"};
	}
	}
	if ( defined $epdata->{official_url} && defined $data->{resource} && $epdata->{official_url} ne $data->{resource} )
	{
		$epdata->{official_url} = $data->{resource};
	}
	if( defined $data->{"volume_title"} )
	{
		$epdata->{book_title} = $data->{"volume_title"};
	}
	if( defined $data->{"journal_title"} )
	{
		$epdata->{publication} = $data->{"journal_title"};
	}
	if( defined $data->{"proceedings_title"} )
	{
		$epdata->{publication} = $data->{"proceedings_title"};
	}
	if( defined $data->{"title"} )
	{
		$epdata->{title} = $data->{"title"};
	}
	if( defined $data->{"subtitle"} )
	{
		$epdata->{title} .= ": " . $data->{"subtitle"};
	}
	if( defined $data->{"publisher_name"} )
	{
		$epdata->{publisher} = $data->{"publisher_name"};
	}
	if( defined $data->{"publisher_place"} )
	{
		$epdata->{place_of_pub} = $data->{"publisher_place"};
	}
	if( defined $data->{"volume"} )
	{
		$epdata->{volume} = $data->{"volume"};
	}
	if( defined $data->{"issue"} )
	{
		$epdata->{number} = $data->{"issue"};
	}

	if( defined $data->{"first_page"} )
	{
		$epdata->{pagerange} = $data->{"first_page"};
		$epdata->{pages} = 1;
	}
	if( defined $data->{"last_page"} )
	{
		$epdata->{pagerange} = "" unless defined $epdata->{pagerange};
		$epdata->{pagerange} .= "-" . $data->{"last_page"};
		$epdata->{pages} = $data->{"last_page"} - $data->{"first_page"} + 1 if defined $data->{"first_page"};
	}

	if( defined $data->{"abstract"} )
	{
		$epdata->{abstract} = $data->{"abstract"};
	}
 
	if( defined $data->{"event_title"} )
	{
		$epdata->{event_title} = $data->{"event_title"};
	}
	if( defined $data->{"event_type"} )
	{
		$epdata->{event_type} = $data->{"event_type"};
	}
	if( defined $data->{"event_location"} )
	{
		$epdata->{event_location} = $data->{"event_location"};
	}
	if( defined $data->{"event_dates"} )
	{
		$epdata->{event_dates} = $data->{"event_dates"};
	}

	if( defined $data->{"type"} )
	{
		$epdata->{type} = $data->{"type"};
	}

	return $epdata;
}

sub url_encode
{
	my ($str) = @_;
	$str =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
	return $str;
}

1;

=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2023 University of Southampton.
EPrints 3.4 is supplied by EPrints Services.

http://www.eprints.org/eprints-3.4/

=for COPYRIGHT END

=for LICENSE BEGIN

This file is part of EPrints 3.4 L<http://www.eprints.org/>.

EPrints 3.4 and this file are released under the terms of the
GNU Lesser General Public License version 3 as published by
the Free Software Foundation unless otherwise stated.

EPrints 3.4 is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with EPrints 3.4.
If not, see L<http://www.gnu.org/licenses/>.

=for LICENSE END


