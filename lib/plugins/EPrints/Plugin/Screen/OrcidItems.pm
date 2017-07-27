package EPrints::Plugin::Screen::OrcidItems;

# This package is used to extend the default Items class to add the ORCID connect button to the Items page.  It requires that the page renders a <div class="ep_act_bar">
# and inserts the ORCID connect button before that div.
#


use Data::Dumper;

@ISA = ( 'EPrints::Plugin::Screen::Items' );

use strict;

sub render {
	my ($self) = @_;
	my $repo = $self->{session};
	my $chunk = $self->SUPER::render();
	my $edited_chunk = $repo->make_doc_fragment;
	my $done = undef;
	my $current_user = $repo->current_user;
print STDERR "\nOrcidItems: edited_chunk start\n";
	return $chunk unless( $current_user->has_role( "ORCID/user" ) );
print STDERR "\nOrcidItems: edited_chunk has role\n";
	foreach my $node ($chunk->getChildNodes)
	{
		my $nodename = $node->nodeName();
		if ( $nodename eq  "div" )
		{
	       		foreach my $attribute ($node->attributes)
			{
print STDERR "\nOrcidItems: edited_chunk ".$attribute->name.": ".$attribute->value."\n";
				if ( $attribute->name eq "class" && !$done && ($attribute->value eq "ep_act_bar" || $attribute->value eq "ep_block") ) 
				{
					my $button_text = $self->html_phrase("orcid_create_button"); #create_text_node( "Create or Connect your ORCID iD");
					my $title_text = $self->html_phrase("orcid_create_button_title");
					if ($current_user->exists_and_set( "orcid" ) && $current_user->exists_and_set( "orcid_auth_code" ))
					{
#						$button_text = $current_user->render_value( "orcid" );
						$button_text = $self->html_phrase("orcid_manage_button");
						$title_text = $self->html_phrase("orcid_linked_button_title");	
					}
					my $button = $repo->xml->create_element("button",
								id => "connect-orcid-button",
								onclick => "document.location='/cgi/users/home?screen=ORCID'",
								title => EPrints::Utils::tree_to_utf8($title_text),
					);
					my $img = $repo->xml->create_element("img",
								id => "orcid-id-logo",
								src => "/images/orcid_24x24.png",
								alt => "ORCID id logo",
								width => "24",
								height => "24",
					);
					$button->appendChild($img);
					$button->appendChild($button_text);
	
					
					$edited_chunk->appendChild($button); #self->html_phrase("orcid_page_link"));
					$done = 1;
##					last;
				}
		
			}
		}
			$edited_chunk->appendChild($node);
print STDERR "\nOrcidItems: edited_chunk\n";
	}

	return $edited_chunk;
}

#set exisiting method as undefined to avoid redefined warning, then redefine
#undef &EPrints::Plugin::Screen::Items::render;
#Define new method and assign to exiting method
#*EPrints::Plugin::Screen::Items::render = $render;

#undef &EPrints::Plugin::Screen::LocalItems::render;
