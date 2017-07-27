package EPrints::Plugin::Screen::ORCID;

use Data::Dumper;
use URI::Escape;

@ISA = ( 'EPrints::Plugin::Screen' );

use strict;

# make the plug-in

sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new(%params);

	# Where the button to access the screen appears if anywhere, and what priority
	$self->{appears} = [
		{
			place => "admin_actions",
			position => 1249,
		},
	];

	$self->{actions} = [qw/ update_local_user_perms erase_granted_perms connect_to_orcid /];
	return $self;
}


# Anyone can see this screen
sub can_be_viewed { 
	my ( $self ) = @_;
	return $self->allow( "ORCID/edit" );
 }

sub allow_update_local_user_perms { return $_[0]->can_be_viewed; }
sub allow_connect_to_orcid { return $_[0]->can_be_viewed; }
sub allow_erase_granted_perms { return $_[0]->can_be_viewed; }

sub action_update_local_user_perms {
	my ( $self ) = @_;
	my $repo = $self->{repository};
	my $userid = $repo->param( "staff_select" );
	my $user = $repo->user( $userid );
	my $name = $user->get_value( "name" );

        my @permissions = @{$repo->config( "ORCID_requestable_permissions" )};
        foreach my $permission ( @permissions )
        {
                my $perm_name = $permission->{ "permission" };
		my $field = $permission->{ "field" };
		if( defined( $field ) )
		{
			if( defined( $repo->param( $perm_name ) ) )
			{
				$user->set_value( $field, "TRUE" );
			}
			else
			{
				$user->set_value( $field, "FALSE" );
			}
		}
	} 
	$user->commit();
	$self->{processor}->add_message(
			"message",
			$self->html_phrase("updated_local_user_perms", name=> $user->render_value( "name" ))
	);

	$self->{processor}->{staff_select} = $userid;
}

sub action_erase_granted_perms {
	my ( $self ) = @_;
	my $repo = $self->{repository};
	my $userid = $repo->param( "staff_select" );
	my $user = $repo->user( $userid );
	my $name = $user->get_value( "name" );
	if( defined ( $user ))
	{
		#create a log entry of the details we are removing... just in case!
		my $log_ds = $repo->dataset( "orcid_log" );
		if( defined( $log_ds ) )
		{
		        my $datestamp =  EPrints::Time::datetime_utc(EPrints::Time::utc_datetime());
		        my $log_entry = $log_ds->create_dataobj({
                        "user"=>$userid,
                        "state"=>"ERASED_PERMS_".$repo->current_user->get_value( "userid" ),
                        "request_time"=>$datestamp,
                        "query"=>$user->get_value( "orcid_granted_permissions" )."`".$user->get_value( "orcid_auth_code" )."`".$user->get_value( "orcid_token_expires" ),
		        });
		        $log_entry->commit();
		}

		$user->set_value( "orcid_granted_permissions", undef );
		$user->set_value( "orcid_auth_code", undef );
		$user->set_value( "orcid_token_expires", undef );
		$user->commit();
		$self->{processor}->add_message(
				"message",
				$self->html_phrase("erased_granted_permissions", name=> $user->render_value( "name" ))
		);
	}

	$self->{processor}->{staff_select} = $userid;
}

sub action_connect_to_orcid {
	my ( $self ) = @_;
	my $repo = $self->{repository};
	my $user = $repo->current_user;
#	print STDERR "ACTO: ".$user->get_value( "userid" )." # ".$repo->param( "/orcid-works/update" );

# Save preferences to user record and redirect to ORCID URL with necessary params - save a copy of the request url in a new database table too!

	#run through permissions defined in config
        my @permissions = @{$repo->config( "ORCID_requestable_permissions" )};
	my @request_permissions;
        foreach my $permission ( @permissions )
        {
                my $perm_name = $permission->{ "permission" };
                my $field = $permission->{ "field" };
                if( defined( $field ) )
                {
			#store value for permission as required
                        if( defined( $repo->param( $perm_name ) ) )
                        {
                                $user->set_value( $field, "TRUE" );
				#and add permission to the request list when selected
				push (@request_permissions, $perm_name);
                        }
                        else
                        {
                                $user->set_value( $field, "FALSE" );
                        }
                }
		else
		{
			#permission not stored locally, so determine whether to use a referred or default value
			if( $permission->{ "use_value" } eq "self" )
			{
				#not a referred field so use default value
				if( $permission->{ "default" } == 1 )
				{
					push ( @request_permissions, $perm_name );
				}
			}
			else
			{
				#use value of a referred field
				if( defined( $repo->param( $permission->{ "use_value" } ) ) )
				{
					push ( @request_permissions, $perm_name );
				}
			}
		}	
        }
	$user->commit();
	$self->{processor}->{staff_select} = $user->get_value( "userid" );
	$self->connect_to_orcid( $user, $repo, @request_permissions );
		
}

sub redirect_to_me_url
{
        my( $self ) = @_;
	
        return $self->SUPER::redirect_to_me_url."&staff_select=".$self->{processor}->{staff_select};
}

sub connect_to_orcid
{
	my( $self, $user, $repo, @request_permissions ) = @_;
	#build referral URI - collate the necessary information

	#return a message if the client id is not defined in the configuration	
	my $client_id = uri_escape($repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"client_id"});
	if( $client_id !~ /^APP-/ )
	{
	        $self->{processor}->add_message(
                        "error",
                        $self->html_phrase("missing_client_id")
	        );
		return;
	}
	
	#Assemble the relevant data for the request
	if(@request_permissions > 1)
	{
		for my $x (0..@request_permissions)
		{
			if( $request_permissions[$x] eq "/authenticate" )
			{
			 @request_permissions = @request_permissions[0..$x-1,$x+1..@request_permissions];
			}
		}
	}
	my $scope = uri_escape(join(" ", @request_permissions));
	my $response_type = "code";
	my $redirect_uri = uri_escape($repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"redirect_uri"});

	#--build a state value from the userid and the current timestamp
	my $state = substr("00000000".$user->get_value("userid"), -8);
	my $timestamp = EPrints::Time::datetime_utc(EPrints::Time::utc_datetime());
	$state .= $timestamp;
	$state = uri_escape(dec_to_base_36( $state ));  # converted to base36 for a shorter string and less apparent what the data is

	my $family_names = uri_escape($user->get_value( "name" )->{ "family" });
	my $given_names = uri_escape($user->get_value( "name" )->{ "given" });
	my $email = uri_escape($user->get_value( "email" ));
        my $lang = uri_escape($repo->param( "defaultlanguage" ) || "en" );
	
	#Build the request from the gathered data 	
	my $request_uri = "?client_id=$client_id";
	$request_uri .= "&scope=$scope";
	$request_uri .= "&response_type=$response_type";
	$request_uri .= "&redirect_uri=$redirect_uri";
	$request_uri .= "&state=$state";
	$request_uri .= "&family_names=$family_names";
	$request_uri .= "&given_names=$given_names";
	$request_uri .= "&email=$email";
	$request_uri .= "&lang=$lang";
	
	$request_uri =  $repo->config( "plugins" )->{"Screen::ORCID"}->{"params"}->{"orcid_org_auth_uri"} . $request_uri;

#get ready to send the user to the request_uri created

	$self->{processor}->{redirect} = $request_uri; 
	
#update the orcid log with the details of this request, for debug and to track valid return messages from ORCID
	my $log_ds = $repo->dataset( "orcid_log" );
	my $log_data = {};
	$log_data->{ "user" } = $user->get_value( "userid" );
	$log_data->{ "state" } = $state;
	$log_data->{ "request_time" } = $timestamp;
	$log_data->{ "query" } = $request_uri;
	my $log_entry = $log_ds->create_dataobj( $log_data );
	$log_entry->commit();
}

sub dec_to_base_36
{
#convert an integer from base 10 to base 36
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

sub render
{
        my ( $self ) = @_;

	# Get the current repository and dataset objects
        my $repo = $self->{repository};
	my $user_ds = $repo->dataset( "user" );

	# Create an XML element to return to our screen
	my $frag = $repo->xml->create_document_fragment();

	# If the orcid field isn't defined in the user dataset, show an error message and stop
	if ( !$user_ds->has_field( "orcid" ))
	{
	$self->{processor}->add_message( "error",
		$self->html_phrase( "no_orcid_error" ));
	return $frag;
	}

	# Get the current user from the repository and store it as the subject of the processing

	my $current_user = $repo->current_user;
	my $selected_user = $current_user;

	# Check to see if the current user is an Admin and add the admin form to the page
	my $admin = 0;
	if ( $current_user->is_staff() )
	{
		$admin = 1;

		#set the selected user from the admin form, if it is set.
		my @params = $repo->param;

		if(defined ($repo->param( "staff_select" ) ) ) 
		{
			my $user_select_id = $repo->param( "staff_select" );
			if ( defined( $user_select_id ) )
			{
				my $select_user_obj = EPrints::DataObj::User->new( $repo, $user_select_id );
				if ( defined ( $select_user_obj ))
				{
					$selected_user = $select_user_obj;
				}
			}
		}
		$frag->appendChild( $self->render_admin_form( $repo, $user_ds, $current_user, $selected_user ) ); 
	}
	
	#Add a title for the general user details
	my $user_title = $repo->xml->create_element( "h3", class => "orcid_subheading" );
	$user_title->appendChild( $self->html_phrase( "user_header", "user_name" => $selected_user->render_value( "name" ) ) );
	$frag->appendChild( $user_title );

	#enable editing local permissions by default
	my $edit_permission = 1;
	# Check if we have received an authorisation code
	if ( $selected_user->exists_and_set( "orcid_auth_code" ) )
	{
		#add details of ORCID permissions we hold for this user
		$frag->appendChild( $self->render_held_permissions( $repo, $selected_user ) );
		
		#if admin user then set flag to render as a form to update local permissions
		$edit_permission = 0;
		$frag->appendChild( $self->render_local_permissions( $repo, $selected_user, $admin, $edit_permission ) );
	}
	else # No authorisation code stored
	{
		#if the selected user is the current user, show the form to request permission (no admin options)
		if ( $selected_user->get_value( "userid" ) == $current_user->get_value( "userid" ) )
		{
			if( $selected_user->exists_and_set( "orcid" ) )
			{
		                my $div = $repo->xml->create_element( "div", class => "orcid_id_display");
		                my $orcid_link = $repo->xml->create_element("a", 
						href=>"http://orcid.org/".$selected_user->get_value( "orcid" ), target=>"_blank"
				);
		                $orcid_link->appendChild($repo->xml->create_element("img", alt=>"ORCID logo", src => "/images/orcid_24x24.png"));
		                $orcid_link->appendChild($repo->xml->create_text_node( " http://orcid.org/".$selected_user->get_value( "orcid" )));
	        	        $div->appendChild($orcid_link);
		                $frag->appendChild($div);
			}	
			$frag->appendChild( $self->html_phrase( "main_text" ) );
			
			$frag->appendChild( $self->render_local_permissions( $repo, $current_user, 0, $edit_permission ) );
		}
		#otherwise render  "no ORCID id / permissions stored" messages
		else
		{
			#if we know the ORCID id, display that, otherwise display a no ORCID id for user message 
			if ( $selected_user->exists_and_set( "orcid" ) )
			{
		                my $div = $repo->xml->create_element( "div", class => "orcid_id_display");
		                my $orcid_link = $repo->xml->create_element("a", 
						href=>"http://orcid.org/".$selected_user->get_value( "orcid" ), target=>"_blank"
				);
		                $orcid_link->appendChild($repo->xml->create_element("img", alt=>"ORCID logo", src => "/images/orcid_24x24.png"));
		                $orcid_link->appendChild($repo->xml->create_text_node( " http://orcid.org/".$selected_user->get_value( "orcid" )));
		                $div->appendChild($orcid_link);
		                $frag->appendChild($div);
			}
			else
			{
				$frag->appendChild( $self->html_phrase( "user_no_orcid_stored", 
							"user_name" => $selected_user->render_value( "name" ) ) );
			}
			
			$frag->appendChild( $self->html_phrase( "user_no_auth_code_stored" ) );
		}
	}
	return $frag;
}

sub render_admin_form
{
	my ( $self, $repo, $user_dataset, $current_user, $selected_user ) = @_;

	#Set up page fragment and add administrative heading and text
	my $admin_frag = $repo->xml->create_document_fragment();
	my $admin_header = $repo->xml->create_element( "h3",
			class=> "orcid_subheading",
			);
	$admin_header->appendChild( $self->html_phrase( "admin_header", "user_name" => $selected_user->render_value( "name" ) ) );
	$admin_frag->appendChild( $admin_header );
	my $admin_text = $repo->xml->create_element( "p",
			class=> "orcid_admin_text",
			);
	$admin_text->appendChild( $self->html_phrase( "admin_text" ) );
	$admin_frag->appendChild( $admin_text );
	
	my $admin_form = $repo->render_form( "GET" );
	$admin_form->appendChild( $repo->render_hidden_field( "screen", $self->{processor}->{screenid} ) );
	$admin_form->setAttribute( "id", "orcid_admin_form" );
	#create a select box for all users in system
	my $staff_select = $repo->xml->create_element( "select",
			"name"	=> "staff_select",
			"id" 	=> "staff_select");
    
	my %options = ("custom_order" => "name/username");
	#build and append the options list to the select box
	my $user_list = $user_dataset->search(%options);
	$user_list->map( sub {
		my( $repo, $dataset, $user ) = @_;
		my $id = $user->get_value("userid");
		my $name= $user->get_value("name");
		my $username=$user->get_value("username");
		my $orcid = $user->get_value("orcid");
		my $class = "orcid_user_select";
		my $selected = 0;
		
		#if the user has an orcid defined, add a class to the option
		if ( $orcid )
		{
			$class .= " with_orcid";
		}
		
		#if the user is the currently selected user, add a class to the option
		if ( $selected_user->get_value( "userid" ) == $id )
		{
			$class .= " current";
			$selected = "selected";
		}
	
		my $option = $repo->xml->create_element("option", value=>$id);	
		$option->setAttribute( "class", $class );
		if ( $selected )
		{
			$option->setAttribute( "selected", "selected" );
		}

		$option->appendChild( $repo->xml->create_text_node( $name->{family}.", ".$name->{given}." ($username)" ) );
		$staff_select->appendChild( $option );
	});
	#Add the submit button to the admin form
	$admin_form->appendChild($staff_select);
	my $button = $repo->xml->create_element( "button",
			"type"	=> "submit",
			"class"	=> "ep_form_action_button",
			"name"	=> "select_user",
			"id"	=> "select_user",
			"value"	=> "do",
			);
	$button->appendChild($self->html_phrase( "admin_user_change_button" ));
	$admin_form->appendChild($button);
	$admin_frag->appendChild($admin_form);
	
	$admin_frag->appendChild($repo->xml->create_element("hr") );
	
	return $admin_frag;
	
}

sub render_held_permissions
{
	my ( $self, $repo, $selected_user ) = @_;
	my $held_frag = $repo->xml->create_document_fragment();
	#if we hold permissions from ORCID, display the user's ORCID Details and list the granted permissions
        if( $selected_user->exists_and_set( "orcid_granted_permissions" ))
        {
		#Display the ORCID
                my $div = $repo->xml->create_element( "div", class => "orcid_id_display");
                my $orcid_link = $repo->xml->create_element("a", 
					href=>"http://orcid.org/".$selected_user->get_value( "orcid" ), target=>"_blank"
		);
                $orcid_link->appendChild($repo->xml->create_element("img", alt=>"ORCID logo", src => "/images/orcid_24x24.png"));
                $orcid_link->appendChild($repo->xml->create_text_node( " http://orcid.org/".$selected_user->get_value( "orcid" )));
                $div->appendChild($orcid_link);
                $held_frag->appendChild($div);
		#Display the granted permissions list
                $held_frag->appendChild($self->html_phrase( "granted_permissions" ));
                my $ulist = $repo->xml->create_element("ul",
                        class=>"permissions_list"
                );
		#make an array of granted permissions
		my @granted_permissions = split(" ", $selected_user->get_value( "orcid_granted_permissions" ));
		#check through each permission defined in config
		foreach my $permission ( @{$repo->config( "ORCID_requestable_permissions" )} )
		{
			my $perm_name = $permission->{"permission"};
			if( $selected_user->get_value( "orcid_granted_permissions" ) =~ m#$perm_name# )
			{
				#make list element for this permission if it was granted
	                        my $list_item = $repo->xml->create_element("li");
        	                $list_item->appendChild($self->html_phrase("permission:$perm_name"));
	               	        $ulist->appendChild($list_item);
				#Remove permission from granted permissions checklist
				for(my $x=0;$x<@granted_permissions;$x++)
				{
					if($granted_permissions[$x] eq $perm_name)
					{
						splice(@granted_permissions,$x,1);
						last;
					}
				}
			}
		}

		#Now add any remaining granted permissions not listed in config
		if(@granted_permissions)
		{
			foreach my $perm_name (@granted_permissions)
			{
				my $list_item = $repo->xml->create_element("li");
				$list_item->appendChild($self->html_phrase("permission:$perm_name"));
				$ulist->appendChild($list_item);
			}
		}
		
                $held_frag->appendChild($ulist);
		

	
		my $held_div = $repo->xml->create_element("div",
			class => "orcid_user_info",
			);
		#Display how long these permissions are due to last, in the local timezone.
		my $localtime = EPrints::Time::datetime_utc(EPrints::Time::split_value($selected_user->get_value("orcid_token_expires")));
                $held_div->appendChild($self->html_phrase( "token_expiry_date", 
					expiry_date => $repo->xml->create_text_node( EPrints::Time::human_time( $localtime ))));
		$held_frag->appendChild($held_div);
        }
#	$frag->appendChild($repo->xml->create_text_node( "held permissions: ".$selected_user->get_value( "username" ) ) );
#	$frag->appendChild($repo->xml->create_element("br") );

	return $held_frag;	
}

sub render_local_permissions
{
	my ( $self, $repo, $selected_user, $admin, $editable ) = @_;
	my $local_frag = $repo->xml->create_document_fragment();
	my $local_perms_div = $repo->xml->create_element("div",
			"class" => "local_perms_div",
			);

	# create form headers for changes submission.
	# this may or may not get included on the page if admin rights or no auth code held
	my $local_perms_form = $repo->render_form( "POST" );
	$local_perms_form->appendChild( $repo->render_hidden_field( "screen", $self->{processor}->{screenid} ) );
	$local_perms_form->appendChild( $repo->render_hidden_field( "staff_select", $selected_user->get_value( "userid" ) ) );
	$local_perms_form->setAttribute( "id", "orcid_local_perms_form" );

	
	#Allow editing the settings boxes if user is an admin or the editable flag is set.
	my $global_disabled = 1;
	$global_disabled = 0 if($admin || $editable);

#print STDERR "\nlocal: $admin / $editable / $global_disabled\n";
	#Work through the permissions listed in config to render them.
	my @permissions = @{$repo->config( "ORCID_requestable_permissions" )};
	foreach my $permission ( @permissions )
	{
		my $perm_name = $permission->{"permission"};
		my $selected = 0;
		my $disabled = $global_disabled;
		my $unavailable = 0;
		# check and set the edit permissions if not already disabled
		if( !$disabled && defined( $permission->{"user_edit"} ) )
		{
#print STDERR "user edit";
			$disabled = 1 - $permission->{"user_edit"};
		}
		if( $admin && defined( $permission->{"admin_edit"} ) )
		{
#print STDERR "admin edit: $admin";
			$disabled = 1 - $permission->{"admin_edit"};
		}

		if( $selected_user->exists_and_set( "orcid_auth_code") && $selected_user->exists_and_set( "orcid_granted_permissions" ) )
		{
			$disabled = 1 unless $selected_user->get_value( "orcid_granted_permissions" ) =~ m#$perm_name#;
			$unavailable = 1 unless $selected_user->get_value( "orcid_granted_permissions" ) =~ m#$perm_name#;
		}

#print STDERR "\n$perm_name: $admin / $editable / $disabled\n";



		#check the permission is set to display
		if( $permission->{"display"} )
		{

			#check the permission setting for the user
			if (defined( $permission->{"field"} ) )
			{
				if ($selected_user->exists_and_set( $permission->{"field"} ) )
				{
					if ( $selected_user->get_value( $permission->{"field"} ) eq "TRUE" )
					{
						$selected = 1;
					}
					else
					{
						$selected = 0;
					}
				}
				else #field not set on user so use default value
				{
					if (defined ($permission->{"default"} ))
					{
						$selected = $permission->{"default"};
					}  # else no idea what value it should be so use the value from variable definition
				}
			}
			else # no database field set for this value so check what the 'use_value' is
			{
				if( defined( $permission->{"use_value"} ))
				{
					if( $permission->{"use_value"} eq "self" )
					{
						# No field defined and using self so use default value
						if( defined( $permission->{"default"} ) )
						{
							$selected = $permission->{"default"};
						}
						else
						{
							#the config is too mashed
							$selected = 99;
						}
					}
					else #Check the referred permission settings
					{
						foreach my $ref_permission (@permissions)
						{
							#search for the matching item
							next unless( $ref_permission->{"permission"} eq $permission->{"use_value"} );
							#throw out the toys if the referred permission also refers on
							if( $ref_permission->{"use_value"} != "self" )
							{
								$selected = 99;
								last;	
							}
							#get the value from the referred permission field
							if( defined ( $ref_permission->{"field"} ))
							{
								if ($selected_user->exists_and_set( $ref_permission->{"field"} ))
								{
									if ($selected_user->get_value( $ref_permission->{"field"} ) eq "TRUE" )
									{
										$selected = 1;
									}
									else
									{	
										$selected = 0;
									}
									last;
								}
								else #referred permission field isn't set
								{
									if (defined ($ref_permission->{"default"} ))
									{
										$selected = $ref_permission->{"default"};
									}  # else no idea what value it should be so use the value from variable definition
									last;
								}
							}
							else #referred_permission field isn't defined so throw out the toys
							{
								$selected = 99;
								last;
							}
						}
					}
				}
				else #use_value not defined - it's all gone a bit wrong again
				{
					$selected = 99;
				}
			}
			#skip the field if the configuration is corrupted;
			next if( $selected == 99 );

			my $input = $repo->xml->create_element( "input",
						class	=> "ep_form_input_checkbox",
						name	=> $permission->{"permission"},
						type	=> "checkbox",
						value	=> 1,
					);
			if( $selected ){
				$input->setAttribute( "checked", "checked" );
			}
			
			if( $disabled ){
				$input->setAttribute( "disabled", "disabled" );
			}
			$local_perms_div->appendChild($input);
			my $permission_title = $repo->xml->create_element("span", "class" => "orcid_permission_title",);
			$permission_title->appendChild($self->html_phrase($permission->{"permission"}."_select_text"));
			$permission_title->setAttribute( "class", "orcid_permission_title disabled") if( $unavailable && $disabled && !$selected);
			$local_perms_div->appendChild($permission_title); #$self->html_phrase($permission->{"permission"}."_select_text"));
			my $description = $repo->xml->create_element("div", class=>"permission_description");
			$description->appendChild($self->html_phrase($permission->{"permission"}."_select_description"));
			$description->setAttribute( "class", "permission_description disabled") if( $unavailable && $disabled && !$selected);
			$local_perms_div->appendChild($description);
		}
#	$local_frag->appendChild($repo->xml->create_text_node( $permission->{"permission"} ));
	}
			#If the form is not editable, just render the tickboxes, otherwise add the form and relevant button elements
			if (!$admin && !$editable)
			{
				$local_frag->appendChild($local_perms_div);
			}
			else
			{
				$local_perms_form->appendChild($local_perms_div);
				
				if( $admin )  # admin update should only be when we have auth code
				{
					my $admin_button = $repo->xml->create_element( "button",
						type=>"submit",
						class => "ep_form_action_button",
						name=>"_action_update_local_user_perms",
						value=>"do",
						);
					$admin_button->appendChild($self->html_phrase( "admin_local_user_perms_button" ));
					$local_perms_form->appendChild($admin_button);
					$admin_button = $repo->xml->create_element( "button",
					type=>"submit",
						class => "ep_form_action_button danger",
						name=>"_action_erase_granted_perms",
						value=>"do",
						onclick=>"if(!confirm(\"".EPrints::Utils::tree_to_utf8($self->html_phrase( "confirm_erase_dialog" ))."\")) return false;",
						);
					$admin_button->appendChild($self->html_phrase( "admin_erase_granted_permissions_button" ));
					$local_perms_form->appendChild($admin_button);
				}
				if( $editable ) # should only be user editable when we don't have auth code
				{
					my $connect_button = $repo->xml->create_element( "button",
						type=>"submit",
						class => "ep_form_action_button",
						name=>"_action_connect_to_orcid",
						value=>"do",
						);
					$connect_button->appendChild($self->html_phrase( "local_user_connect_orcid_button" ));
					$local_perms_form->appendChild($connect_button);
				}

				$local_frag->appendChild($local_perms_form);
			}
	
#	$local_frag->appendChild($repo->xml->create_text_node( "local permissions: ".$selected_user->get_value( "username" ) ) );
#	$local_frag->appendChild($repo->xml->create_element("br") );

	return $local_frag;	
}



# What to display
sub old_render
{
	my( $self ) = @_;
	my $eprints = undef;
	# Get the current repository object (so we can access the users, eprints information about things in this repository)
	my $repository = $self->{repository};

	# Create an XML element to return to our screen
	my $frag = $repository->xml->create_document_fragment();
	my $br = $repository->xml->create_element("br");
	my $ds = $repository->dataset( "user" );
	if (!$ds->has_field("orcid"))
	{
		$self->{processor}->add_message(
			"error",
			$self->{repository}->html_phrase("no_orcid_error")
		);
		return $frag;
	}


	# Fill the fragment with stuff
	my $current_user = $repository->current_user;
	my $selected_user = $current_user;
	my $admin = 0;
	if ($current_user->is_staff())
	{
		$admin = 1;
		$frag->appendChild($br);
	
		$frag->appendChild($self->html_phrase("admin_text"));
		my $staff_select = $repository->xml->create_element( "select",
			name=>"staff_select");
		my %options = ("custom_order" => "name/username");
		my $user_list = $ds->search(%options);

		$user_list->map( sub {
                	my( $repo, $dataset, $user ) = @_;
                        my $id = $user->get_value("userid");
                        my $name= $user->get_value("name");
			my $username=$user->get_value("username");
                        my $orcid = $user->get_value("orcid");
			my $class = "user_select";
                        if ( $orcid )
			{
				$class = "user_select with_orcid";
			}
                        my $option = $repo->xml->create_element( "option", class => "$class", value=>"$id" );
                        $option->appendChild( $repo->xml->create_text_node( $name->{family}.", ".$name->{given}." ($username)" ) );
                      $staff_select->appendChild( $option );
                    
                });
		$frag->appendChild($staff_select);
		$frag->appendChild($repository->xml->create_element("hr"));
	}

	if( $selected_user->exists_and_set( "orcid_granted_permissions" ))
	{
		my $div = $repository->xml->create_element( "div", class => "orcid_id_display");
		my $orcid_link = $repository->xml->create_element("a", href=>"http://orcid.org/".$selected_user->get_value( "orcid" ), target=>"_blank");
		$orcid_link->appendChild($repository->xml->create_element("img", alt=>"ORCID logo", src => "/images/orcid_24x24.png"));
		$orcid_link->appendChild($repository->xml->create_text_node( " http://orcid.org/".$selected_user->get_value( "orcid" )));
		$div->appendChild($orcid_link);
		$frag->appendChild($div);
		$frag->appendChild($br);
		$frag->appendChild($self->html_phrase( "granted_permissions" ));
		my $ulist = $repository->xml->create_element("ul",
			class=>"permissions_list"
		);
		
		foreach my $permission (sort(split(" ", $selected_user->get_value( "orcid_granted_permissions" ))))
		{
			my $list_item = $repository->xml->create_element("li");
			$list_item->appendChild($self->html_phrase("permission:$permission"));
			$ulist->appendChild($list_item);
		}
		$frag->appendChild($ulist);
		$frag->appendChild($self->html_phrase( "token_expiry_date", expiry_date => ( $selected_user->render_value( "orcid_token_expires" ))));
		$frag->appendChild($br);
	}
	my $disabled = 0;
	my $button;
	$frag->appendChild($repository->xml->create_element("br"));
	if ($selected_user->exists_and_set( "orcid_auth_code" ))
	{
		$frag->appendChild($br);
		$frag->appendChild($br);
		$frag->appendChild($self->html_phrase("post_approval_main_text"));
		$frag->appendChild($br);
		$frag->appendChild($br);
		$frag->appendChild($br);
		$disabled = 1;	

	}
	else 
	{
		$frag->appendChild($self->html_phrase("main_text"));
		$frag->appendChild($repository->xml->create_element("br"));
		$frag->appendChild($repository->xml->create_element("br"));
	        $button = $repository->xml->create_element( "button",
	                        form=>"orcid_select_form",
	                        type=>"submit",
				class => "ep_form_action_button",
	                        name=>"orcid_auth",
	                        value=>"orcid_auth" );
	        $button->appendChild( $self->html_phrase("connect_button"));#$repository->xml->create_text_node( "Connect to ORCID" ) );
		$frag->appendChild($br);
		$frag->appendChild($br);
	}
	
	my $authenticate = $repository->xml->create_element( "input", class => "ep_form_input_checkbox", name=>"authenticate", type=>"checkbox", value=>"authenticate", checked=>"checked", disabled=>"disabled" );
	$frag->appendChild($authenticate);
	
	$frag->appendChild($self->html_phrase("connect_to_orcid"));
	$frag->appendChild($repository->xml->create_element("br"));
	my $description = $repository->xml->create_element("div", class=>"permission_description");
	$description->appendChild($self->html_phrase("authenticate_description"));
	$frag->appendChild($description);


	$frag->appendChild($repository->xml->create_element("br"));
	my $read_limited = $repository->xml->create_element( "input", class => "ep_form_input_checkbox", name=>"read_limited", type=>"checkbox", value=>"read_limited", checked=>"checked" );
	$read_limited->setAttribute( "disabled", "disabled") if ($disabled && !$admin);
	$frag->appendChild($read_limited);
	$frag->appendChild($self->html_phrase("read_limited"));
	$frag->appendChild($repository->xml->create_element("br"));
	$description = $repository->xml->create_element("div", class=>"permission_description");
	$description->appendChild($self->html_phrase("read_limited_description"));
	$frag->appendChild($description);

	$frag->appendChild($repository->xml->create_element("br"));
	my $works_update = $repository->xml->create_element( "input", class => "ep_form_input_checkbox", name=>"works_update", type=>"checkbox", value=>"works_update", checked=>"checked" );
	$works_update->setAttribute( "disabled", "disabled") if ($disabled && !$admin);
	$frag->appendChild($works_update);
	$frag->appendChild($self->html_phrase("works_update"));
	$frag->appendChild($repository->xml->create_element("br"));
	$description = $repository->xml->create_element("div", class=>"permission_description");
	$description->appendChild($self->html_phrase("works_update_description"));
	$frag->appendChild($description);

	$frag->appendChild($repository->xml->create_element("br"));
	my $affiliations = $repository->xml->create_element( "input", class => "ep_form_input_checkbox", name=>"affiliations", type=>"checkbox", value=>"affiliations", checked=>"checked" );
	$affiliations->setAttribute( "disabled", "disabled") if ($disabled && ! $admin);
	$frag->appendChild($affiliations);
	$frag->appendChild($self->html_phrase("affiliations"));
	$frag->appendChild($repository->xml->create_element("br"));
	$description = $repository->xml->create_element("div", class=>"permission_description");
	$description->appendChild($self->html_phrase("affiliations_description"));
	$frag->appendChild($description);

	if ($current_user->is_staff())
	{
		$frag->appendChild($br);
		$frag->appendChild($br);
	        my $admin_button = $repository->xml->create_element( "button",
	                        form=>"orcid_select_form",
	                        type=>"submit",
				class => "ep_form_action_button",
	                        name=>"local_permission_update",
	                        value=>"local_permission_update" );
	        $admin_button->appendChild( $self->html_phrase("local_permission_button"));
		$frag->appendChild($admin_button);
	}

	if (!$disabled && $current_user == $selected_user ){
		$frag->appendChild($br);
		$frag->appendChild($br);
		$frag->appendChild($button);
	}
#	if (defined $eprints and $eprints->count > 0)
#	{
#		$eprints->map(sub {
#			my( undef, undef, $eprint ) = @_;
#		
#			$frag->appendChild($eprint->render_citation("default"));
#			$frag->appendChild($repository->make_element("br"));
#		});
#	}

foreach my $node ($frag->getChildNodes){
 print STDERR $node->nodeName().": ".$node->nodeValue().": ".EPrints::XML::is_dom( $node, "NodeList" )."\n";
}
	return $frag;
}

1;
