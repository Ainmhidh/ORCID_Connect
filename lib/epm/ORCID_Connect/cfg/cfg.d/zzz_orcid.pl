$c->{"plugins"}->{"Screen::ORCID"}->{"params"}->{"disable"} = 0;   # enable this plugin 
$c->{"plugins"}->{"Event::OrcidSync"}->{"params"}->{"disable"} = 0; # enable the updates plugin
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"client_id"} = "YYYY"; # Add your client id here in place of YYYY
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"client_secret"} = "XXXX"; # Add your client secret here in place of XXXX
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"http_proxy"} = undef; # proxy string or undef
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"https_proxy"} = undef; # proxy string or undef
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"redirect_uri"} = $c->{"perl_url"}."/orcid/authenticate"; # should direct to your cgi directory and then down a level

#These 3 ORCID addresses should be replaced by the values commented out to the right when you have a live system client_id
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"orcid_org_auth_uri"} = "https://sandbox.orcid.org/oauth/authorize"; # "https://orcid.org/oauth/authorize";
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"orcid_org_exch_uri"} = "https://api.sandbox.orcid.org/oauth/token"; # "https://api.orcid.org/oauth/token;
$c->{"plugins"}{"Screen::ORCID"}{"params"}{"orcid_org_use_uri"} = "https://api.sandbox.orcid.org/v1.2"; # "https://api.orcid.org/v1.2";

#Details of the organization for affiliation inclusion - the easiest way to obtain the RINGGOLD id is to add it to your ORCID user record manually, then pull the orcid-profile via the API and the identifier will be on the record returned.
$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"organization"} = {
                                                "name" => "My University Name", #name of organization - REQUIRED
                                                "address" => {
                                                        "city" => "My Town",  # name of the town / city for the organization - REQUIRED if address included
						#	"region" => "Countyshire",  # region e.g. county / state / province - OPTIONAL
                                                        "country" => "GB",  # 2 letter country code - AU, GB, IE, NZ, US, etc. - REQUIRED if address included
                                                },
                                                "disambiguated-organization" => {
                                                        "disambiguated-organization-identifier" => "ZZZZ",  # replace ZZZZ with Institutional identifier from the recognised source
                                                        "disambiguation-source" => "RINGGOLD", # Source for institutional identifier should be RINGGOLD or ISNI
                                                }
};

$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"department"} = sub {

	my ( $user ) = @_;
#return the formatted value for department of the user to update_affiliations - format: { "department" => dept_string_value };
#e.g. use the dept defined on the user record
#
#	return undef unless( defined ( $user ));
#	if( $user->exists_and_set( "dept" ) )
#	{
#		my $retval = $user->get_value( "dept" );
#		return $retval ;
#	}

	return undef;
};

$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"start_date"} = sub {

#return the formatted value for user start date to update_affiliations - format: { "start_date" => {"year" => year_val, ["month" => month_val, ["day" => day_val]] }};# square brackets above indicate optional values - can submit just year / year + month / year + month + day.  Values must be numerical not string

	my ( $user ) = @_;

#Could include the value from eprints user date of registration like this: 
#	return undef unless( defined( $user ));
#	if( $user->exists_and_set( "joined" ) )
#	{
#		my @start_date = EPrints::Time::split_value($user->get_value( "joined" ));
#		my $ret_val = {};
#		$ret_val->{"year"} = 0+$start_date[0];  #0+ to force numerical value from string
#		if( defined( $start_date[1] )) {$ret_val->{"month"} = 0+$start_date[1];} #0+ to force numerical value from string
#		if( defined( $start_date[2] )) {$ret_val->{"day"} = 0+$start_date[2];} #0+ to force numerical value from string
#		return $ret_val;	
#	}
		
	return undef;
};

# contributor types mapping from EPrints to ORCID - used in Event::OrcidSync to add contributor details to orcid-works and when importing works to eprints
$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"contributor_map"} = {
	#	eprint field name	=> ORCID contributor type,
		"creators"		=> "AUTHOR",
		"editors"		=> "EDITOR",
};

# flag to control whether the system adds 'orcid' fields to the listed contributor fields
$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"add_orcid_to_contributors"} = 1;

# How many days to keep log information before erasing it. 0 is don't delete.
$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"keep_log_days"} = 0;

# work types mapping from EPrints to ORCID
# defined separately from the called function to enable easy overriding.
$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"work_type"} = {
		"article" 		=> "JOURNAL_ARTICLE",
		"book_section" 		=> "BOOK_CHAPTER",
		"monograph" 		=> "BOOK",
		"conference_item" 	=> "CONFERENCE_PAPER",
		"book" 			=> "BOOK",
		"thesis" 		=> "DISSERTATION",
		"patent" 		=> "PATENT",
		"artefact" 		=> "OTHER",
		"exhibition" 		=> "OTHER",
		"composition" 		=> "OTHER",
		"performance" 		=> "ARTISTIC_PERFORMANCE",
		"image" 		=> "OTHER",
		"video" 		=> "OTHER",
		"audio" 		=> "OTHER",
		"dataset" 		=> "DATA_SET",
		"experiment" 		=> "OTHER",
		"teaching_resource"	=> "OTHER",
		"other"			=> "OTHER",
};

$c->{"plugins"}{"Event::OrcidSync"}{"work_type"} = sub {
#return the ORCID work-type based on the EPrints item type.
#default EPrints item types mapped in $c->{"plugins"}{"Event::OrcidSync"}{"params"}{"work_type"} above.
#ORCID acceptable item types listed here: https://members.orcid.org/api/supported-work-types
#Defined as a function in case there you need to replace it for more complicated processing
#based on other-types or conference_item sub-fields
	my ( $eprint ) = @_;
	my %work_types = %{$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"work_type"}};
	
	if( defined( $eprint ) && $eprint->exists_and_set( "type" ))
	{
		my $ret_val = $work_types{ $eprint->get_value( "type" ) };
		if( defined ( $ret_val ) )
		{
			return $ret_val;
		}
	}
#if no mapping found, call it 'other'
	return "OTHER";
};


# get the email address for queries about ORCID functionality - used in phrases
# default value is the repository admin email.
$c->{ORCID_contact_email} = $c->{adminemail};

#each permission defined below with some default behaviour (basic permission description commented by each item)
#default - 1 or 0 = this item selected or not selected on screen by default
#display - 1 or 0 = show or show not the option for this item on the screen at all
#admin-edit - 1 or 0 = admins can or can not change this option once users have obtained ORCID authorisation token
#user-edit - 1 or 0 = user can or can not change this option prior to obtaining ORCID authorisation token
#use-value = take the value for this option from the option of another permission e.g. include create if we get update
# **************** AVOID CIRCULAR REFERENCES IN THIS !!!! *******************
# Full Access is granted by the options not commented out below

$c->{ORCID_requestable_permissions} = [
			{	"permission" => "/authenticate",		#basic link to ORCID ID
				"default" => 1,
				"display" => 1,
				"admin_edit" => 0,
				"user_edit" => 0,
				"use_value" => "self",
				"field" => undef,
			},

			{	"permission" => "/activities/update",		#update research activities created by this client_id (implies create)
				"default" => 1,
				"display" => 1,
				"admin_edit" => 1,
				"user_edit" => 1,
				"use_value" => "self",
				"field" => "orcid_update_works",
			},

			{	"permission" => "/orcid-bio/update",		#update education/employment history added by this client_id (implies create)
				"default" => 1,
				"display" => 1,
				"admin_edit" => 1,
				"user_edit" => 1,
				"display" => 1,
				"use_value" => "self",
				"field" => "orcid_update_profile",
			},

			{	"permission" => "/orcid-profile/read-limited",	#read information from ORCID profile which the user has set to trusted parties only
				"default" => 1,
				"display" => 1,
				"admin_edit" => 1,
				"user_edit" => 1,
				"use_value" => "self",
				"field" => "orcid_read_record",
			},

#### These options below show how more selective permissions could be configured - NOTE They use some of the same field names as above, and the 'create' values refer
#### to the relevant 'update' values (and don't display the 'create' permission request) to merge them both into one tick box permission.
#### If you name different fields you will need to create them on the 'user' dataset and may need to add relevant phrases for new permissions.
#
#			{	"permission" => "/orcid-works/create",		#create new publication entries
#				"default" => 1,
#				"display" => 0,
#				"admin_edit" => 0,
#				"user_edit" => 0,
#				"display" => 0,
#				"use_value" => "/orcid-works/update",
#				"field" => undef,
#			},

#			{	"permission" => "/orcid-works/update",		#update publications entries created by this client_id (implies create)
#				"default" => 1,
#				"display" => 1,
#				"admin_edit" => 1,
#				"user_edit" => 1,
#				"use_value" => "self",
#				"field" => "orcid_update_works",
#			},

#			{	"permission" => "/affiliations/create",		#add education/employment history
#				"default" => 1,
#				"display" => 0,
#				"admin_edit" => 0,
#				"user_edit" => 0,
#				"use_value" => "/affiliations/update",
#				"field" => undef,
#			},

#			{	"permission" => "/affiliations/update",		#update education/employment history added by this client_id (implies create)
#				"default" => 1,
#				"display" => 1,
#				"admin_edit" => 1,
#				"user_edit" => 1,
#				"display" => 1,
#				"use_value" => "self",
#				"field" => "orcid_update_profile",
#			},
		];

#Add fields to user record to hold various details for ORCID functionality - don't change these!

$c->add_dataset_field('user',
	{
		name => 'orcid',
		type => 'text',
	},
		reuse => 1	
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_auth_code',
		type => 'text',
		show_in_html => 0,
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_granted_permissions',
		type => 'text',	
		show_in_html => 0,
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_token_expires',
		type => 'time',
		render_res => 'minute',
		render_style => 'long',
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_last_update_timestamp',
		type => 'text',
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_read_record',
		type => 'boolean',
		show_in_html => 0,
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_update_works',
		type => 'boolean',	
		show_in_html => 0,
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_update_profile',
		type => 'boolean',	
		show_in_html => 0,
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	);
$c->add_dataset_field('user',
	{
		name => 'orcid_webhook_ref',
		type => 'text',
		show_in_html => 0,
		export_as_xml => 0,
		import => 0,
	},
		reuse => 1
	);

#Add 'orcid' field to all relevant contributor fields from the parameters set above
if( $c->{"plugins"}{"Event::OrcidSync"}{"params"}{"add_orcid_to_contributors"} )
{
	my %contributor_fields = %{$c->{"plugins"}{"Event::OrcidSync"}{"params"}{"contributor_map"}};
	foreach my $key ( keys %contributor_fields )
	{
		foreach my $field (@{$c->{'fields'}->{'eprint'}})
		{
			if( $field->{'name'} eq $key )
			{
				push (@{$field->{'fields'}}, {
					'sub_name' => 'orcid',
					'type' => 'text',
					'input_cols' => 16,
					'allow_null' => 1,
					
				});
				last;
			}
		}
	}
}

#Add put-code field to eprint dataset to track ORCID items we have seen and processed.
$c->add_dataset_field('eprint',
        {
                name => 'orcid_put_codes',
                type => 'text',
		multiple => 1,
                show_in_html => 0,
                export_as_xml => 0,
                import => 0,
        },
                reuse => 1
        );

#Add trigger on eprint_commit to trigger update of items into ORCID records
$c->add_dataset_trigger( "eprint", EP_TRIGGER_AFTER_COMMIT, sub{
	my ( %params ) = @_;
	my $timestamp = join("-",EPrints::Time::iso_datetime(600+EPrints::Time::datetime_utc(EPrints::Time::utc_datetime())));
	my $repo = $params{"repository"};
	return undef if( !defined( $repo ));

	if( defined( $params{"dataobj"} ))
	{
		my $eprint = $params{"dataobj"};
		return undef unless( $eprint->get_value("eprint_status") eq "archive" );
		my $md5 = Digest::MD5->new;
		$md5->add( "Event::OrcidSync" );
		$md5->add( "process_single_eprint" );
		$md5->add( $eprint->get_value( "eprintid" ) );
                $repo->dataset( "event_queue" )->create_dataobj({
				"pluginid" => "Event::OrcidSync",
				"action" => "process_single_eprint",
				"params" => ["/id/eprint/".$eprint->get_value( "eprintid" )],
				"start_time" => $timestamp,
				"eventqueueid" => $md5->hexdigest,				
                                });
	}
});



#override the default User Workarea field to include the Connect to ORCID button
$c->{plugin_alias_map}->{"Screen::Items"} = "Screen::OrcidItems";
$c->{plugin_alias_map}->{"Screen::OrcidItems"} = undef;

#set roles & permissions to allow specific individuals to access ORCID functionality.
$c->{roles}->{"ORCID/user"} = [ "ORCID/edit" ];

#create a dataset for storing log information about orcid communications
#helpful for debugging - by default deletes records on a daily basis
#where the entry is more than a specified threshold
{
no warnings;

package EPrints::DataObj::OrcidLog;

@EPrints::DataObj::OrcidLog::ISA = qw( EPrints::DataObj );

sub get_dataset_id { "orcid_log" }

sub get_url { shift->uri }

sub get_defaults
{
        my( $class, $session, $data, $dataset ) = @_;

        $data = $class->SUPER::get_defaults( @_[1..$#_] );

        return $data;
}

}

$c->{datasets}->{orcid_log} = {
	sqlname => "orcid_log",
	class => "EPrints::DataObj::OrcidLog",
	index => 0,
	};
$c->add_dataset_field('orcid_log',
	{
		name => 'id',
		type => "counter",
		sql_counter => "orcid_log",
	});
$c->add_dataset_field('orcid_log',
	{
		name => 'user',
		type => "int", 
	});
$c->add_dataset_field('orcid_log',
	{
		name => 'state',
		type => "text", 
	});
$c->add_dataset_field('orcid_log',
	{
		name => 'request_time',
		type => "int", 
	});
$c->add_dataset_field('orcid_log',
	{
		name => 'query',
		type => "longtext", 
	});
