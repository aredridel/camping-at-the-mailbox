#!/usr/sbin/ruby

require 'camping'
require 'net/imap'

$imap = {}

Camping.goes :Mailbox
module Mailbox
	include Camping::Session

	module IMAP
		def _imap
			$imap[@cookies.camping_sid]
		end
	end

	module Controllers
		class Login < R '/login'
			include IMAP
			def post
				$imap[@cookies.camping_sid] = Net::IMAP.new('mail.theinternetco.net')
				begin
					_imap.authenticate('LOGIN', input.username, input.password)
					@login = 'login success !'
					redirect Mailboxes
				rescue Net::IMAP::NoResponseError => e
					@login = 'wrong user name or password'
				end
				render :login
			end

			def get
				render :login
			end
		end

		class Mailboxes < R '/mailboxes'
			include IMAP
			def get
				@mailboxes = _lsub('', '*')
				render :mailboxes
			end
		end
	end

	module Views
		def layout
			html do
				head do
					title 'Webmail'
					link :rel => 'stylesheet', :type => 'text/css', 
							:href => '/styles.css', :media => 'screen'
				end
				body do
					#h1.header { a 'Mail?', :href => R(Index) }
					div.content do
						self << yield
					end
				end
			end
		end

		def login
			form :action => R(Login), :method => 'post' do
				label 'Username', :for => 'username'; br
				input :name => 'username', :type => 'text'; br

				label 'Password', :for => 'password'; br
				input :name => 'password', :type => 'text'; br

				input :type => 'submit', :name => 'login', :value => 'Login'
			end

			p { b @login }
		end

		def mailboxes
			
		end

	end
end
