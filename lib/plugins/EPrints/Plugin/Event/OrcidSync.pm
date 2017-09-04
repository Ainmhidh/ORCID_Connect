package EPrints::Plugin::Event::OrcidSync;

our @ISA = qw( EPrints::Plugin::Event );

use strict;
use utf8;
use EPrints;
use JSON;
use Encode;
use LWP::UserAgent;
use HTTP::Request::Common;
use Data::Dumper;
use EPrints::Plugin::Event;


sub read_all_works 
{
	my ( $self, $user ) = @_;
	#Check we have all the relevant data objects
	die "read_all_works: User object not defined" unless( defined( $user ) );
	my $repo = $self->{"repository"};
	die "read_all_works: Repository object not defined" unless( defined( $repo ) );
	die "Orcid id or authorisation code not set for user ".$user->get_value( "userid" ) unless( $user->exists_and_set( "orcid" ) && $user->exists_and_set( "orcid_auth_code" ) );
	my $destination = "orcid-works";

	my $response = $self->communicate_with_orcid( $user->get_value( "userid" ), $user->get_value( "orcid" ), $user->get_value( "orcid_auth_code"), "read", $destination, undef );
	if( $response->is_success )
	{
		return $response;
	}
	else
	{
		#problem with the communication
		die "Response from ORCID:".$response->code." ".$response->content;
	}
}

sub import_user_works
{
	my ( $self, $user ) = @_;
	my $repo = $self->{"repository"};	
	my $response = $self->read_all_works( $user );               
        my $json = new JSON;
        my $json_text = $json->utf8->decode($response->content);
 
        if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"} ) )
        {
		#we have something defined in activities
		if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"}->{"orcid-works"}->{"orcid-work"} ) )
		{
			#and we have some works defined so process them
                        my $client_id = $repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"client_id"};

			#get and update the orcid record last modified date for this user
		        my $user_last_mod_ts = $user->get_value("orcid_last_modified_timestamp");
			$user->set_value( "orcid_last_modified_timestamp", EPrints::Time::datetime_utc(EPrints::Time::utc_datetime()) );
			$user->commit();

                        foreach my $work ( @{$json_text->{"orcid-profile"}->{"orcid-activities"}->{"orcid-works"}->{"orcid-work"}} )
                        {
				#ignore the item if we put it on ORCID
                                next if( defined( $work->{"source"}->{"source-client-id"}->{"path"} ) && $work->{"source"}->{"source-client-id"}->{"path"} eq $client_id );

				#has this work been updated since we last reveiwed the user record?
				my $last_mod_ts = $work->{"last-modified-date"}->{"value"};
				next unless( $last_mod_ts > $user_last_mod_ts );
				
				#We're probably interested in this item so process it
				$self->process_work($repo, $user, $work);
			}
		}
	}
}

sub process_work
{
	my ( $self, $repo, $user, $work ) = @_;
	
	#Search for the work put-code on existing eprints
	my $putcode = $work->{"put-code"};
	my $putcode_items = $repo->dataset( 'eprint' )->search(
				filters =>
				[
					{ meta_fields=>["orcid_put_code"], value => $putcode, match=>"EQ" },
				]
	);
	if ( $putcode_items->count() > 0 )
	{	
		#if we found it, update the details and flag the change for admin review
		foreach my $eprint( @$putcode_items )
		{
			$self->update_eprint($repo, $eprint, $work, undef);
		}
	}
	else
	{
		#Didn't find the put-code - do we have a matching DOI?
		my $doi = undef;
		foreach my $external_id (@{$work->{"work-external-identifiers"}->{"work-external-identifier"}})
		{
			next unless ($external_id->{"work-external-identifier-type"} eq "DOI" );
			$doi = $external_id->{"work-external-identifier-id"}->{"value"};
			last;
		}
		if( defined( $doi ) )
		{
			my $doi_items = undef;
			if( $repo->database->has_field( $repo->dataset( "eprint" ), "doi" ))
			{ 
			        $doi_items = $repo->dataset( "eprint" )->search(
			                              filters =>
        			                      [
                			                      { meta_fields=>["doi"], value => $doi, match=>"EQ" },
	                       			      ]
			        );
			}
			else
			{
				$doi_items = $repo->dataset( 'eprint' )->search(
							filters =>
							[
								{ meta_fields=>["idnumber"], value => $doi, match => "IN" },
							]
				);
			}
			if( $doi_items->count() > 0 )
			{
		                #if we found it, update the details and flag the change for admin review
				foreach my $eprint( @$doi_items )
				{
					$self->update_eprint($repo, $eprint, $work, $putcode);
				}
			}
			else
			{
				#We didn't find the DOI locally so create a new item and flag for admin review
				my $eprint = $repo->dataset( 'eprint' )->create_dataobj({
									"eprint_status" => "buffer",
									"userid" => $user->get_value( "userid" ),											
									 });
				$eprint->commit();
				$self->update_eprint($repo, $eprint, $work, $putcode);
			}
		}
		else
		{
			#No DOI so create new item and flag for review.
			my $eprint = $repo->dataset( 'eprint' )->create_dataobj({
								"eprint_status" => "buffer",
								"userid" => $user->get_value( "userid" ),											
								 });
			$eprint->commit();
			$self->update_eprint($repo, $eprint, $work, $putcode);
		}
	}
}

sub update_eprint
{
	my ($self, $repo, $eprint, $work, $putcode) = @_;

	if( defined( $work->{"work-title"}->{"title"}->{"value"} ) )
	{
		$eprint->set_value( "title", $work->{"work-title"}->{"title"}->{"value"} );
	}
	
	if( defined( $work->{"journal-title"} ) )
	{
		$eprint->set_value( "publication" , $work->{"journal-title"} );
	}

	if( defined( $work->{"short-description"} ) )
	{
		$eprint->set_value( "abstract", $work->{"short-description"} );
	}

	if( defined( $work->{"url"} ) )
	{
		$eprint->set_value( "official_url", $work->{"url"}->{"value"} );
	}

	if( defined( $work->{"work-external-identifiers"}->{"work-external-identifier"} ) )
	{
		foreach my $identifier (@{$work->{"work-external-identifiers"}->{"work-external-identifier"}} )
		{
			if( $identifier->{"work-external-identifier-type"}->{"value"} eq "DOI" )
			{
				if( $repo->database->has_field( $repo->dataset( "eprint" ), "doi" ) )
				{
					$eprint->set_value( "doi", $identifier->{"work-external-identifier-id"}->{"value"} );
				}
				else
				{
					$eprint->set_value( "id_number", "doi".$identifier->{"work-external-identifier-id"}->{"value"} );
				}
				last;
			}
		}
	}
	if( defined( $work->{"work-contributors"} ) )
	{
		foreach my $contributor (@{$work->{"work-contributors"}->{"contributor"}} )
		{
			my $username = undef;

			if( defined( $contributor->{"contributor-orcid"} ) )
			{
				#search for user with orcid and add username to eprint contributor if found
				my $user = $self->user_with_orcid( $repo, $contributor->{"contributor-orcid"}->{"path"} );

				#What kind of contributor is this?  Pull match from config
				my $contrib_role = $contributor->{"contributor-attributes"}->{"contributor-role"};
				my %contrib_config = $repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"contributor_map"};
				foreach my $contrib_type ( keys %contrib_config )
				{
					if( $contrib_config{$contrib_type} eq $contrib_role )
					{
						$contrib_role = $contrib_config{$contrib_type};
						
					}
				}
				
				#add orcid to contributor
			}
				#add name to contributor
		}
	}
	
	#map work type to eprint type from config.

	if( !defined( $putcode ))
	{
		#no putcode means the eprint is already linked so we're just updating the item

	}

	#flag this item for review purposes.

}

sub user_with_orcid
{
# copy of EPrints::DataObj::User::user_with_username/email but for ORCID id
	my ( $self, $repo, $orcid ) = @_;
	my $dataset = $repo->dataset( "user" );
	
	$orcid = $repo->get_database->ci_lookup(
			$dataset->field( "orcid" ),
			$orcid
		);
	
	my $results = $dataset->search(
			filters => [
				{
					meta_fields => [qw( orcid )],
					value => $orcid, match => "EX",
				}
			]);
	return $results->item( 0 );
}

 
sub read_profile 
{
	my ( $self, $user ) = @_;
	#Check we have all the relevant data objects
	die "read_profile: User object not defined" unless( defined( $user ) );
	my $repo = $self->{"repository"};
	die "read_profile: Repository object not defined" unless( defined( $repo ) );
	die "read_profile: Orcid id or authorisation code not set for user ".$user->get_value( "userid" ) unless( $user->exists_and_set( "orcid" ) && $user->exists_and_set( "orcid_auth_code" ) );
	my $destination = "orcid-profile";

	my $response = $self->communicate_with_orcid( $user->get_value( "userid" ), $user->get_value( "orcid" ), $user->get_value( "orcid_auth_code"), "read", $destination, undef );
	if( $response->is_success )
	{
		return $response;
	}
	else
	{
		#problem with the communication
		die "Response from ORCID:".$response->code." ".$response->content;
	}
}


sub update_affiliation
{
	my ( $self, $user ) = @_;

	#get user object for relevant details - check it exists and has appropriate fields
	my $repo = $self->{repository};
	die "Repository or User object not defined" unless (defined( $repo ) && defined( $user ));
	die "Orcid id or authorisation code not set for user ".$user->get_value( "userid" ) unless( $user->exists_and_set( "orcid" ) && $user->exists_and_set( "orcid_auth_code" ) );

	#get details for the communication from config - check they exist
	my $organisation = $repo->config( "plugins" )->{"Event::OrcidSync"}->{"params"}->{"organization"};
	die "Organization not defined correctly in configuration"  unless ( defined( $organisation ));


	#check if we have already created a profile on the ORCID record to determine whether to create or update the profile
	#NOTE: Assuming we are only maintaining one affiliation record as we have no historical detail over role / deparmental changes
	my $client_id = $repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"client_id"};
	my $create_update = "create";  #default to create
	my $profile = $self->read_profile( $user );
	my $json = new JSON;
	my $json_text = $json->utf8->decode($profile->content);
	if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"} ) )
	{
		#we have something defined in activities
		if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"}->{"affiliations"} ) )
		{
			#and some affiliations have been defined
			#process the affiliations for an employment from our client id
			foreach my $affiliation ( @{$json_text->{"orcid-profile"}->{"orcid-activities"}->{"affiliations"}->{"affiliation"}} )
			{
				next unless( $affiliation->{"type"} eq "EMPLOYMENT" );
				next unless( defined( $affiliation->{"source"}->{"source-client-id"} ) 
						&& $affiliation->{"source"}->{"source-client-id"}->{"path"} eq $client_id);
				$create_update = "update";
				last;
			}
		}
	}

	#construct the affiliation record for the individual
	my $destination = "affiliations";
	my $content = { "message-version" => "1.2" };
	my $org_details = [{	
			"type" => "EMPLOYMENT",
			"organization" =>  $organisation ,
	}];
	my $dept = &{$repo->config( "plugins" )->{"Event::OrcidSync"}->{"params"}->{"department"}}($user);
	my $start_date = &{$repo->config( "plugins" )->{"Event::OrcidSync"}->{"params"}->{"start_date"}}($user);
	if( defined( $dept ) ) {$org_details->[0]->{"department-name"} = $dept;}
	if( defined( $start_date ) ) {$org_details->[0]->{"start-date"} = $start_date;}
	
	$content->{"orcid-profile"}->{"orcid-activities"}->{"affiliations"}->{"affiliation"} = $org_details;

	my $response = $self->communicate_with_orcid( $user->get_value( "userid" ), $user->get_value( "orcid" ), $user->get_value( "orcid_auth_code"), $create_update, $destination, $content );
	if( $response->is_success )
	{
		return EPrints::Const::HTTP_OK;
	}
	else
	{
		#problem with the communication
		die "Response from ORCID:".$response->code." ".$response->content;
	}
}


sub update_all_works_for_user
{
	#Get list of all eprints connected with the user - derive eprints fields to check and the value to which they should be compared from the plugin config.
	my ( $self, $user ) = @_;
	die "update_all_works: Can't get user object" unless defined($user);
	my $repo = $self->{"repository"};
	die "update_all_works: Can't get repository object" unless defined($repo);
	my $ep_ds = $repo->dataset( "archive" ); 	
	die "update_all_works: Cant get eprint dataset" unless defined ($ep_ds);

	my $searchexp = $ep_ds->prepare_search();
	$searchexp->add_field(
		fields=> [ $ep_ds->field( "creators_id" ), $ep_ds->field( "editors_id" ) ], value => $user->get_value( "username" ));
	my $eprints_list = $searchexp->perform_search;

	if( $eprints_list->count() <= 0 ) #no eprints found from search so log it and end.
	{
	        my $log_ds = $repo->dataset( "orcid_log" );
	        my $datestamp =  EPrints::Time::datetime_utc(EPrints::Time::utc_datetime());
	        my $state = $user->get_value( "userid" ).$datestamp;
	        my $log_entry = $log_ds->create_dataobj({
                                        "user"=>$user->get_value( "userid" ),
                                        "state"=>"UPDATE_ALL_WORKS_".$state,
                                        "request_time"=>$datestamp,
                                        "query"=>"No works found to send to ORCID for user ".$user->get_value( "userid" ),
                        });
	        $log_entry->commit();

		return EPrints::Const::HTTP_OK;
	}

	#We have at least one existing eprint so check whether ORCID holds any from us to determine if this is a create or update
	my $create_update = "create";
	my $destination = "orcid-works";
	my $response = $self->read_all_works($user);
	my $json = new JSON;
	my $json_text = $json->utf8->decode($response->content);
	if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"} ) )
	{
		#we have something defined in activities
		if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"}->{"orcid-works"}->{"orcid-work"} ) )
		{
			#and we have some works defined - check if they are from us
		        my $client_id = $repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"client_id"};
			
			foreach my $work ( @{$json_text->{"orcid-profile"}->{"orcid-activities"}->{"orcid-works"}->{"orcid-work"}} )
			{
				next unless ( defined( $work->{"source"}->{"source-client-id"}->{"path"} ) && $work->{"source"}->{"source-client-id"}->{"path"} eq $client_id );
				$create_update = "update";
				last;				
			}
		}
	}

	#build a list of details to send to ORCID
	my $orcid_works = [];
	$eprints_list->map( \&collate_work, $orcid_works );
	my $orcid_message = {"message-version" => 1.2,
				"orcid-profile" =>	{
					"orcid-activities" =>	{
						"orcid-works" =>	{
							"orcid-work" =>	$orcid_works,
									}
								},
							},
	};
		
	$response = $self->communicate_with_orcid( $user->get_value( "userid" ), $user->get_value( "orcid" ), $user->get_value( "orcid_auth_code"), $create_update, $destination, $orcid_message );
	if( $response->is_success )
	{
		return EPrints::Const::HTTP_OK;
	}
	else
	{
		#problem with the communication
		die "Response from ORCID:".$response->code." ".$response->content;
	}
}


sub collate_work
{
	my( $repo, $dataset, $eprint, $orcid_works ) = @_;
	my $work = { "work-title" => {
			"title" => $eprint->get_value( "title" ),
		},};

	$work->{"work-type"} = &{$repo->config( "plugins" )->{"Event::OrcidSync"}->{"work_type"}}($eprint);

	#set journal title, if relevant
	if( $eprint->exists_and_set( "type" ) && $eprint->get_value( "type" ) eq "article" && $eprint->exists_and_set( "publication" ) )
	{
		$work->{"journal-title"} = $eprint->get_value( "publication" );
	}
	
	#add abstract, if relevant
	if( $eprint->exists_and_set( "abstract" ) )
	{
		$work->{"short-description"} = curtail_abstract( $eprint->get_value( "abstract" ) );
	}

	my $bibtex_plugin = EPrints::Plugin::Export::BibTeX->new();
	$bibtex_plugin->{"session"} = $repo;
	$work->{"work-citation"} = {
		"work-citation-type" => "BIBTEX",
		"citation" => $bibtex_plugin->output_dataobj( $eprint ),
	};

	#publication date
	if( $eprint->exists_and_set( "date" ) )
	{
		$work->{"publication-date"} = {
			"year" => 0 + substr( $eprint->get_value( "date" ),0,4),
			"month" => length( $eprint->get_value( "date" )) >=7 ? 0 + substr( $eprint->get_value( "date" ),5,2) : undef,
			"day" => length( $eprint->get_value( "date" )) >=9 ? 0 + substr( $eprint->get_value( "date" ),8,2) : undef,
		}
	}

	$work->{"work-external-identifiers"} = {"work-external-identifier" => [
				{"work-external-identifier-type"	=> "SOURCE_WORK_ID",
				"work-external-identifier-id"	=> $eprint->get_value( "eprintid" ),},
				{"work-external-identifier-type" => "URI",
                                "work-external-identifier-id"   => $eprint->get_url,},
	]};
	my $doi = undef;
	if( $eprint->exists_and_set( "doi" ) && $eprint->get_value( "doi" ) =~ m#(doi:)?[doixrg.]*(10\..*)$# )
	{
		$doi = $2;
	}
	if( !defined( $doi ) && $eprint->exists_and_set( "id_number" ) && $eprint->get_value( "id_number" ) =~ m#(doi:)?[doixrg./]*(10\..*)$# )
	{
		$doi = $2;
	}	
	
	if( defined( $doi ) )
	{
		push ( @{$work->{"work-external-identifiers"}->{"work-external-identifier"}}, {
				"work-external-identifier-type"	=> "DOI",
				"work-external-identifier-id"	=> $doi,
			});
	}
	if( $eprint->exists_and_set( "official_url" ) )
	{
		$work->{"url"} = $eprint->get_value( "official_url" ); 
	}

	my $contributors = [];
	my %contributor_mapping = %{$repo->config( "plugins" )->{"Event::OrcidSync"}->{"params"}->{"contributor_map"}};
	foreach my $contributor_role ( keys %contributor_mapping )
	{

		if( $eprint->exists_and_set( $contributor_role ))
		{
			foreach my $contributor (@{$eprint->get_value( $contributor_role )})
			{
				push (@$contributors, {"credit-name" => $contributor->{"name"}->{"family"}.", ".$contributor->{"name"}->{"given"},
								"contributor-attributes" => {"contributor-role" => $contributor_mapping{$contributor_role}},
							});
				if( defined( $contributor->{"orcid"} ))
				{
					$contributors->[-1]->{"contributor-orcid"} = $contributor->{"orcid"};	
				}
			}
		}
	}
	$work->{"work-contributors"}->{"contributor"} = $contributors;

	push (@$orcid_works, { %$work });
}


sub create_one_work
{
	my ( $self, $user, $eprint ) = @_;
	die "update_all_works: Can't get user object" unless defined($user);
	die "update_all_works: Cant get eprint" unless defined ($eprint);
	my $repo = $self->{"repository"};
	die "update_all_works: Can't get repository object" unless defined($repo);
	my $ep_ds = $repo->dataset( "archive" ); 	
	die "update_all_works: Cant get eprint dataset" unless defined ($ep_ds);

	#check the item doesn't already exist on ORCID via us
	my $create_update = "create";
        my $response = $self->read_all_works($user);
        my $json = new JSON;
        my $json_text = $json->utf8->decode($response->content);
        if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"} ) )
        {
		#we have something defined in activities
		if( defined( $json_text->{"orcid-profile"}->{"orcid-activities"}->{"orcid-works"}->{"orcid-work"} ) )
		{
			#and we have some works defined - check if this one exists from us
                        my $client_id = $repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"client_id"};

                        foreach my $work ( @{$json_text->{"orcid-profile"}->{"orcid-activities"}->{"orcid-works"}->{"orcid-work"}} )
                        {
                                next unless ( defined(	$work->{"source"}->{"source-client-id"}->{"path"} ) && 
							$work->{"source"}->{"source-client-id"}->{"path"} eq $client_id );
                                next unless ( defined(	$work->{"work-external-identifiers"}->{"work-external-identifier"})); 
				foreach my $identifier ( @{$work->{"work-external-identifiers"}->{"work-external-identifer"}} )
				{
					next unless( $identifier->{"work-external-identifier-type"} eq "SOURCE_WORK_ID" );
					next unless( $identifier->{"work-external-identifier-id"} eq $eprint->id );
					#item exists, from us, with the eprint id stored, so do update
                                	$create_update = "update";
					last;
				}
                                last;
                        }
                }
	}
	if( $create_update eq "update" )
	{
		#item already exists on ORCID user record, call an update all works rather than create a new item.
		$self->update_all_works_for_user($user);
		return EPrints::Const::HTTP_OK;
	}
	
	#item doesn't already exist on ORCID user record so create the new item
	my $destination = "orcid-works";
	my $orcid_works = [];
	$self->collate_work($user, $ep_ds, $eprint, $orcid_works );
	# create message for new item
	my $orcid_message = {"message-version" => 1.2,
				"orcid-profile" =>	{
					"orcid-activities" =>	{
						"orcid-works" =>	{
							"orcid-work" =>	$orcid_works,
									}
								},
							},
	};
	#send file to ORCID
	$response = $self->communicate_with_orcid( $user->get_value( "userid" ), $user->get_value( "orcid" ), $user->get_value( "orcid_auth_code"), $create_update, $destination, $orcid_message );
	if( $response->is_success )
	{
		return EPrints::Const::HTTP_OK;
	}
	else
	{
		#problem with the communication
		die "Response from ORCID:".$response->code." ".$response->content;
	}
}

sub process_single_eprint
{
	#Event called from eprint_commit trigger
        my ( $self, $eprint ) = @_;
        die "update_all_works: Cant get eprint" unless defined ($eprint);
        my $repo = $self->{"repository"};
        die "update_all_works: Can't get repository object" unless defined($repo);
	
	#Process through eprint contributor fields, get user record and check for orcid id
	die "process_single_eprint function not complete";
	
}


sub communicate_with_orcid
{
	my ( $self, $userid, $orcid, $auth_code, $comm_flag, $destination, $content ) = @_;

	die "Invalid value specified for communication type flag: $comm_flag" unless ($comm_flag eq "create" || $comm_flag eq "update" || $comm_flag eq "read");

	my $repo = $self->{"repository"};
        #Store the request on the ORCID_log
	my $log_ds = $repo->dataset( "orcid_log" );
	my $update_uri = $repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"orcid_org_use_uri"};
        my $datestamp =  EPrints::Time::datetime_utc(EPrints::Time::utc_datetime());
        my $state = $userid.$datestamp;
        my $log_entry = $log_ds->create_dataobj({
                                        "user"		=> $userid,
                                        "state"		=> uc($comm_flag).uc($destination)."_".$state,
                                        "request_time"	=> $datestamp,
                                        "query"		=> $update_uri."/".$orcid."/".$destination."?".( defined( $content ) ? to_json( $content ) : ""),
                        });
        $log_entry->commit();

        #send affiliation record to ORCID.

        my $ua = LWP::UserAgent->new;
        $ua->env_proxy;

        $ua->proxy('https',$repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"https_proxy"});
        $ua->proxy('http',$repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"http_proxy"});
	
	
	my $request = GET($update_uri."/".$orcid."/".$destination); #assume read request by default
	$request = PUT($update_uri."/".$orcid."/".$destination) if( $comm_flag eq "update" );
        $request = POST($update_uri."/".$orcid."/".$destination) if( $comm_flag eq "create" );
        $request->header( "Content-Type" => "application/vnd.orcid+json" );
        $request->header( "Accept" => "application/json" );
        $request->header( "Authorization" => "Bearer ".$auth_code );
	if( defined( $content ) )
	{
#		$content = encode("iso-8859-1",$content);
	        $request->header( "Content-Length" => length( encode_utf8(to_json($content)) ) );
	        $request->content( encode_utf8(to_json( $content )));
	}

        my $response = $ua->request($request);

	$log_entry = $log_ds->create_dataobj({
			"user"=>$userid,
			"state"=>"RESPONSE".uc($destination)."_".$state,
			"request_time"=>$datestamp,
			"query"=>$response->code."\n".$response->content,
	});
	$log_entry->commit();

	return $response;	

}

sub dec_to_base_36
{
#convert a value from base 10 to base 36
	my ( $value ) = @_;
	return 0 unless ($value > 0);
	my @nums = (0..9,'a'..'z');
	my $retval = "";
	while ( $value > 0 )
	{
		$retval = $nums[$value % 36] .$retval;
		$value = int( $value / 36 );
	}
	return $retval;
}

sub curtail_abstract
{
        my ( $abstract ) = @_;
        return $abstract unless ( length( $abstract ) > 5000 );
        $abstract = substr($abstract,0,4990);
        if ( $abstract =~ /(.+)\b\w+$/ )
        {
                $abstract = $1;
        }
        $abstract .= " ...";
        return $abstract;
}

1;
