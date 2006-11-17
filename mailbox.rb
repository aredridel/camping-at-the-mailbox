#!/usr/sbin/ruby

require 'camping'
require 'net/imap'

$residentsession = Hash.new do |h,k| h[k] = {} end if !$residentsession
$config = YAML.load(File.read('mailbox.conf'))

Flagnames = { :Seen => 'read', :Answered => 'replied to' }

Camping.goes :Mailbox
module Mailbox
	include Camping::Session

	module Helpers
		def imap
			residentsession[:imap]
		end

		def envelope
			@message.attr['ENVELOPE']
		end

		def residentsession
			$residentsession[@cookies.camping_sid]
		end
	end

	module Controllers
		class Index < R '/'
			def get
				redirect Login
			end
		end

		class Login < R '/login'
			def post
				residentsession[:imap] = Net::IMAP.new($config['server'])
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
				 if !@mailboxes
					@error = 'You have no folders subscribed, showing everything'
					@mailboxes = imap.list('', '*')
				end
				@mailboxes = @mailboxes.sort_by { |mb| [if mb.name == 'INBOX' then 1
else 2 end, mb.name.downcase] }
				render :mailboxes
			end
		end

		class Mailbox < R '/mailbox/(.+)/messages/'
			def get(mb)
				@mailbox = mb
				imap.select(mb)
				@total = imap.responses["EXISTS"][-1].to_i
				@unread = imap.responses["RECENT"][-1].to_i
				if @total > 0 
					fin = if @total > 10
						10
					else
						@total
					end
					@messages = imap.fetch(1..fin, ['FLAGS', 'ENVELOPE', 'UID'])
				end
				render :mailbox
			end
		end

		class Style < R '/styles.css'
			def get
				@headers['Content-Type'] = 'text/css; charset=UTF-8'
				@body = %{
					body {
						font-family: Gentium, Palatino, Palladio, serif;
						background-color: #df7;
						color: #452;
						margin-left: 1in;
						margin-top: 1in;
						margin-right: 2in;
					}	
					a { color: #573; }
					a:visited { color: #341; }
					a:active { color: #900; }
					.message p { margin: 0; }
					.error { color: #900 }
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

		class Header < R '/mailbox/(.*)/messages/(\d+)/headers'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				imap.select(mailbox)
				@header = imap.uid_fetch(@uid, ['RFC822.HEADER'])[0].attr['RFC822.HEADER']
				render :header
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
					div(:class => 'error') do
						@error
					end if @error
					div.content do
						self << yield
					end
				end
			end
		end

		def login
			p $config['banner']
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
			h1 "#{@mailbox} (#{@total} total)"
			if @total == 0
				p "No messages"
				return
			end
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
									if env.date
										Time.parse(env.date).strftime('on %Y/%m/%d at %H:%M')
									else
										'(no date)'
									end
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
			h1 "#{@mailbox} message #{@message.seqno}"
			p do 
				span "From " 
				envelope.from.each do |f|
					cite(:title => f.mailbox + '@' + f.host) { f.name || f.mailbox }
				end
				span " on " + (envelope.date || 'none')
			end
			p envelope.subject
			pre do
				@message.attr['RFC822.TEXT'].gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
			end
		end

		def header
			pre do
				@header.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
			end
		end

	end
end
