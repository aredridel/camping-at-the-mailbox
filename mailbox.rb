#!/usr/sbin/ruby

require 'camping'
require 'net/imap'

$imap = {} if !$imap
Flagnames = { :Seen => 'read', :Answered => 'replied to' }

Camping.goes :Mailbox
module Mailbox
	include Camping::Session

	module Helpers
		def imap
			$imap[@cookies.camping_sid]
		end
	end

	module Controllers
		class Login < R '/login'
			def post
				$imap[@cookies.camping_sid] = Net::IMAP.new('mail.theinternetco.net')
				begin
					imap.authenticate('LOGIN', input.username, input.password)
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
			def get
				@mailboxes = imap.lsub('', '*')
				render :mailboxes
			end
		end

		class Mailbox < R '/mailbox/(.+)/messages/'
			def get(mb)
				@mailbox = mb
				imap.select(mb)
				@messages = imap.fetch(1..10, ['FLAGS', 'ENVELOPE', 'UID'])
				render :mailbox
			end
		end

		class Style < R '/styles.css'
			def get
				@headers['Content-Type'] = 'text/css; charset=UTF-8'
				@body = %{
					body {
						font-family: Gentium, Palatino, Palladio, serif;
						background-color: #ffd;
						margin-left: 1in;
						margin-top: 1in;
						margin-right: 2in;
					}	
					.message p { margin: 0; }
				}
			end
		end

		class Message < R '/mailbox/(.*)/messages/(\d+)'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				imap.select(mailbox)
				@message = imap.uid_fetch(@uid, ['ENVELOPE', 'RFC822.TEXT'])[0]
				render :message
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
				input :name => 'password', :type => 'password'; br

				input :type => 'submit', :name => 'login', :value => 'Login'
			end

			p { b @login }
		end

		def mailboxes
			ul do
				@mailboxes.each do |mb|
					li do
						a(mb.name, :href => R(Mailbox, mb.name))
					end
				end
			end
		end

		def mailbox
			h1 "#{@mailbox}"
			table do
				@messages.each do |message|
					$stderr.puts message.inspect
					env = message.attr['ENVELOPE']
					flags = message.attr['FLAGS']
					tr(:class => 'message') do
						td do
							p do 
								span { 'From ' }
								cite(:title => env.from[0].mailbox + '@' + env.from[0].host) do
									env.from[0].name || env.from[0].mailbox 
								end
								span(:class => 'date') {
									Time.parse(env.date).strftime('%Y/%m/%d %H:%M')
								}
								if !flags.empty? then
									flags.map { |e| Flagnames[e] }.join(', ')
								end
							end
							p do
								a(env.subject, :href => R(Message, @mailbox, message.attr['UID']))
							end 
						end
					end
				end
			end
		end

		def message	
			p "Mailbox #{@mailbox} message uid #{@uid}"
			@message.attr['RFC822.HEADER'].each do |l|
				p l
			end
			@message.attr['RFC822.TEXT'].each do |l|
				p l
			end
		end

	end
end
