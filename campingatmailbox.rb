#!/usr/sbin/ruby

require 'camping'
require 'net/imap'
require 'net/imap2'

$residentsession = Hash.new do |h,k| h[k] = {} end if !$residentsession
$config = YAML.load(File.read('mailbox.conf'))

Flagnames = { :Seen => 'read', :Answered => 'replied to' }

Camping.goes :CampingAtMailbox
module CampingAtMailbox
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

		def decode(structure)
			case structure.encoding
			when 'BASE64'
				@parts[structure.part_id].unpack('m*')
			when 'QUOTED-PRINTABLE'
				@parts[structure.part_id].gsub(/\r\n/, "\n").unpack('M*')
			else @parts[structure.part_id]
			end
		end
		
		def get_mailbox_list
			@mailboxes = imap.lsub('', '*')
			 if !@mailboxes
				@error = 'You have no folders subscribed, showing everything'
				@mailboxes = imap.list('', '*')
			end
			@mailboxes = @mailboxes.sort_by { |mb| [if mb.name == 'INBOX' then 1 else 2 end, mb.name.downcase] }
		end

		def fetch_structure
			@message = imap.uid_fetch(@uid, ['ENVELOPE', 'BODYSTRUCTURE'])[0]
			@structure = @message.attr['BODYSTRUCTURE']
			@parts = Hash.new do |h,k|
				h[k] = imap.uid_fetch(@uid, "BODY[#{k}]")[0].attr["BODY[#{k}]"]
			end
			@structureindex = {}
			index_structure(@structure)
		end

		def index_structure(structure)
			@structureindex[structure.part_id] = structure
			case structure
			when Net::IMAP::BodyTypeMultipart
				structure.parts.each do |part|
					index_structure part
				end
			when Net::IMAP::BodyTypeMessage
				index_structure structure.body
			end
		end
		
		def Pager(controller, current, total, n, *args)
			pages = total / n + (total % n == 0 ? 0 : 1)
			p do
				(1..pages).map do |page|
					if page == current
						text page
					else
						a(page, :href => R(controller, *args) + "?page=#{page}")
					end
				end
			end if pages > 1
		end
	end

	module Controllers
		class Index < R '/'
			def get
				redirect Login
			end
		end

		# You see a locked door.
		#
		class Login < R '/login'
			
			# The key opens the door. You slip inside. 
			# 
			# See Mailboxes
			def post
				residentsession[:imap] = Net::IMAP.new($config['server'])
				residentsession[:pinger] = Thread.new do 
					while !residentsession[:imap].disconnected? and residentsession[:imap]
						residentsession[:imap].noop
						sleep 60
					end
				end
				caps = imap.capability
				begin
					if /AUTH=LOGIN/ === caps
						imap.authenticate('LOGIN', input.username, input.password)
					else
						imap.login(input.username, input.password)
					end
					redirect Mailboxes
				rescue Net::IMAP::NoResponseError => e
					@error = 'wrong user name or password'
				end
				render :login
			end

			# You slip your key in the lock.
			#
			def get
				render :login
			end
		end

		# You see a room with row upon row of shiny brass doors. 
		# Which door do you open?
		#
		class Mailboxes < R '/mailboxes'

			# You open a Mailbox 
			#
			def get
				get_mailbox_list
				render :mailboxes
			end
		end

		# Inside the box seems to be a room. You climb through the tiny brass
		# door, surprised at how roomy the inside of the box is. There seems
		# to be a pile of packages to the left, and a simple writing desk on the
		# right.
		#
		# Off in the distance, a faint 'whoopwhoop' noise can be heard.
		#
		class Mailbox < R '/mailbox/(.+)/messages/'
			
			# Suddenly, there's a whizthunk! and you see an arrow embed itself 
			# in the wall next to your head. There seems to be a Message attached.
			#
			def get(mb)
				@mailbox = mb
				imap.select(mb)
				@uidlist = imap.uid_search('UNDELETED')
				@total = @uidlist.length
				if @input.page.to_i > 0 
					@page = @input.page.to_i
					start = (@page - 1) * 10 + 1
					fin = if @page * 10 > @total then @total else @page * 10 end
				else
					@page = 1
					start = 1
					fin = if @total > 10
						10
					else
						@total
					end
				end
				if @total > 0 
					@messages = imap.uid_fetch(@uidlist[start..fin], ['FLAGS', 'ENVELOPE', 'UID'])
				end
				render :mailbox
			end
		end

		# A snappily dressed mailman stands over a postal scale in the front
		# lobby.
		#
		class Style < R '/styles.css'
			def get
				@headers['Content-Type'] = 'text/css; charset=UTF-8'
				@body = %{
					@media print { .controls {display: none;} }
					body {
						font-family: Gentium, Palatino, Palladio, serif;
						background-color: #df7;
						color: #452;
						margin-left: 1in;
						margin-top: 1in;
						margin-right: 2in;
						margin-bottom: 1in;
					}	
					a { color: #573; }
					a:visited { color: #341; }
					a:active { color: #900; }
					.header p { margin: 0; padding: 0; }
					.header p.subject { text-indent: 1em; }
					.header p.controls { text-indent: 1em; }
					p.messagepartheader { margin-bottom: 0;}
					.error { color: #900 }
					.message { margin-left: 2em; }
					.fin { text-indent: 2in; }
				}
			end
		end

		# There is a scroll tacked to the wall with an arrow. You take it 
		# down and read it.
		#
		class Message < R '/mailbox/(.*)/messages/(\d+)'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				imap.select(mailbox)
				fetch_structure
				render :message
			end
		end
		
		# An inner piece of parchment flutters to the ground as you unroll
		# the scroll. You pick it up and read it.
		#
		class MessagePart < R '/mailbox/(.*)/messages/(\d+)/parts/(.*)'
			def get(mailbox, uid, part)
				@mailbox = mailbox
				@uid = uid.to_i
				imap.select(mailbox)
				fetch_structure
				@part = @structureindex[part]
				case @part
				when Net::IMAP::BodyTypeMultipart
					render :messagepart
				when Net::IMAP::BodyTypeMessage
					render :messagepart
				else
					$stderr.puts @part.encoding
					@headers['Content-Type'] = @part.media_type.downcase << '/' << @part.subtype.downcase
					@body = decode(@part)
				end
			end
		end
		
		# There seems to be another object tied to the arrow.
		#
		class Attachment < R '/mailbox/(.*)/messages/(\d+)/attachment/(.*)'
			def get(mailbox, uid, part)
				@mailbox = mailbox
				@uid = uid.to_i
				@part = part
				imap.select(mailbox)
				fetch_structure
				render :attachment
			end
		end

		# You examine the scroll and arrow for signs of its origin.
		#
		class Header < R '/mailbox/(.*)/messages/(\d+)/headers'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				imap.select(mailbox)
				@header = imap.uid_fetch(@uid, ['RFC822.HEADER'])[0].attr['RFC822.HEADER']
				render :header
			end
		end

		# There is a large, red button here. 
		#
		class DeleteMessage < R '/mailbox/(.*)/messages/(\d+)/delete'

			# You press it to see what it does.
			#
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				render :deleteq
			end

			# There is a loud klaxon and the scroll you were holding in your 
			# hand disappears
			#
			def post(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				if input.deletemessage == uid
					imap.uid_store(@uid, '+FLAGS', [:Deleted])
					redirect Mailbox, mailbox
				else
					render :deleteq
				end
			end
		end

		# You realize that there's a better place to keep the scroll than
		# wrapped around an arrow on the outside of the building. You move
		# it to a safer location.
		#
		class MoveMessage < R '/mailbox/(.*)/messages/(\d+)/move'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				get_mailbox_list
				render :movemessage
			end
			def post(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				imap.uid_copy(@uid, input.folder)
				imap.uid_store(@uid, '+FLAGS', [:Deleted])
				redirect Mailbox, mailbox
			end
		end

	end

	module Views
		def layout
			html do
				head do
					title 'Webmail'
					link :rel => 'stylesheet', :type => 'text/css', 
							:href => '/styles.css'
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
		end
	
		def deleteq
			form :action => R(DeleteMessage, @mailbox, @uid), :method => 'post' do
				p 'Are you sure you want to delete this message?'
				input :type => 'hidden', :name => 'deletemessage', :value => @uid
				input :type => 'submit', :value => 'Confirm'
			end
		end

		def movemessage
			form :action => R(MoveMessage, @mailbox, @uid), :method => 'post' do
				ul do
					@mailboxes.each do |mb|
						li do 
							input :type => 'radio', :name => 'folder', :value => mb.name
							text mb.name
						end
					end
				end
				input :type => 'submit', :value => 'Move message'
			end
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
					env = message.attr['ENVELOPE']
					flags = message.attr['FLAGS']
					tr(:class => 'header') do
						td do
							p.envelope do 
								text 'From ' 
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
							p.subject do
								a(if !env.subject or env.subject.strip.empty? then 'no subject' else env.subject end, :href => R(Message, @mailbox, message.attr['UID']))
							end 
						end
					end
				end
			end
			Pager(Mailbox, @page, @total, 10, @mailbox)
		end

		def _messageheader(envelope, controls = false)
			div.header do 
				p do 
					text "From " 
					envelope.from.each do |f|
						cite(:title => f.mailbox + '@' + f.host) { f.name || f.mailbox }
					end
					text (Time.parse(envelope.date).strftime('on %Y/%m/%d at %H:%M') || 'none')
				end if envelope.from
				p do
					text "To "
					envelope.to.each do |t|
						cite(:title => t.mailbox + '@' + t.host) { t.name || t.mailbox }
					end
				end if envelope.to
				p do
					text "Carbon copies to "
					envelope.cc.each do |t|
						cite(:title => t.mailbox + '@' + t.host) { t.name || t.mailbox }
					end
				end if envelope.cc
				p do
					text "Also copies to "
					envelope.bcc.each do |t|
						cite(:title => t.mailbox + '@' + t.host) { t.name || t.mailbox }
					end
				end if envelope.bcc
				p.subject envelope.subject
				_messagecontrols if controls
			end
		end

		def message	
			_messageheader(envelope, true)
			_message(@structure)
			p.fin '❧'
		end

		def _messagecontrols
			p.controls do
				a 'delete', :href => R(DeleteMessage, @mailbox, uid)
				a 'move', :href => R(MoveMessage, @mailbox, uid)
				a 'headers', :href => R(Header, @mailbox, uid)
				a 'reply'#, :href => R(ReplyToMessage, @mailbox, uid)
				a 'forward'#, :href => R(ForwardMessage, @mailbox, uid)
			end
		end

		def _messagepartheader(part)
				p.messagepartheader do
					a("Part #{part.part_id}", :href => R(MessagePart, @mailbox, @uid, part.part_id)) 
					text case part
						when Net::IMAP::BodyTypeMessage
							'(included message)'
						else
							(if part.disposition && part.disposition.dsp_type != 'INLINE' then '(attachment) ' else '' end ) + 'type ' + part.media_type.downcase + '/' + part.subtype.downcase
					end + ' '
					small part.description if part.respond_to? :description
				end
		end

		def _message(structure, depth = 0, maxdepth = 1)
			case structure
			when Net::IMAP::BodyTypeMessage
				div.message do
					_messageheader(structure.envelope)
					_message(structure.body, depth - 1, maxdepth) if depth <= maxdepth
				end
			when Net::IMAP::BodyTypeMultipart
				if structure.subtype == 'ALTERNATIVE'
					_message(structure.parts.sort_by do |part|
						[
							if part.media_type == 'TEXT': 0 else 1 end,
							case part.media_type
							when 'PLAIN': 0 
							when 'HTML': 1
							else 2
							end
						]
					end.first, depth + 1, maxdepth)
				else
					structure.parts.each_with_index do |part,i|
						div.message do
							if !part.disposition or part.disposition.dsp_type == 'INLINE'
								if depth <= maxdepth
									_message(part, depth + 1, maxdepth)
								else
									_messagepartheader(part)
								end
							else
								_messagepartheader(part)
								_attachment(part)
							end
						end
					end
				end
			when Net::IMAP::BodyTypeText
				pre WordWrapper.wrap(decode(structure))
			else
				_messagepartheader(structure)
				_attachment(structure)
			end
		end

		def _attachment(part)
			p do
				# FIXME -- change options depending on whether it's a browser-viewable type or not
				a('view', :href =>  R(MessagePart, @mailbox, @uid, part.part_id))
				a('download', :href => R(Attachment, @mailbox, @uid, part.part_id))
			end
		end

		def header
			pre do
				@header.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
			end
		end

		def messagepart
			_messagepartheader @part if Net::IMAP::BodyTypeMessage === @part
			_message @part
		end

		def attachment
			p @part.inspect
		end

	end
end

module WordWrapper
	extend self
	def wrap(text, margin = 76)
		output = ''
		text.each do |paragraph|
			if (paragraph !~ /^>/)
				paragraph = wrap_paragraph(paragraph, margin - 1)
			end
			output += paragraph
		end
		return output
	end

	private
	def wrap_paragraph(paragraph, width)
		lineStart = 0
		lineEnd = lineStart + width
		while lineEnd < paragraph.length
			newLine = paragraph.index("\n", lineStart)
			if newLine && newLine < lineEnd
				lineStart = newLine+1
				lineEnd = lineStart + width
				next
			end
			tryAt = lastSpaceOnLine(paragraph, lineStart, 
lineEnd)
			paragraph[tryAt] = paragraph[tryAt].chr + 
"\n"
			tryAt += 2
			lineStart = findFirstNonSpace(paragraph, 
tryAt)
			paragraph[tryAt...lineStart] = ''
			lineStart = tryAt
			lineEnd = lineStart+width
		end
		return paragraph
	end

	def findFirstNonSpace(text, startAt)
		startAt.upto(text.length) do
			| at |
			if text[at] != 32
				return at
			end
		end
		return text.length
	end

	def lastSpaceOnLine(text, lineStart, lineEnd)
		lineEnd.downto(lineStart) do |tryAt|
			case text[tryAt].chr
				when ' ', '-'
					return tryAt
			end
		end
		return lineEnd
	end
end
