#!/usr/bin/ruby

require 'camping'
require 'net/imap'
require 'net/imap2'
require 'net/smtp'
require 'dbi'
require 'stringio'
require 'iconv'
require 'hpricot'

$residentsession = Hash.new do |h,k| h[k] = {} end if !$residentsession

class Net::IMAP
	def idle
		cmd = "IDLE"
		synchronize do
			tag = generate_tag
			put_string(tag + " " + cmd)
			put_string(CRLF)
		end
	end
	def done
		cmd = "DONE"
		synchronize do
			put_string(cmd)
			put_string(CRLF)
		end
	end
end

class ReconnectingIMAP
	class ReconnectNeeded < Exception; end

	def initialize(*args)
		@initargs = args
		@connection = Net::IMAP.new(*args)
	end

	def login(*args)
		@loginargs = args
		@loginmethod = :authenticate
		@connection.send(:login, *args)
	end

	def select(*args)
		@selectargs = *args
		@connection.send(:select, *args)
	end

	def authenticate(*args)
		@loginargs = args
		@loginmethod = :authenticate
		@connection.send(:authenticate, *args)
	end

	def reconnect
		initialize(*@initargs)
		send(@loginmethod, *@loginargs)
		select(*@selectargs) if @selectargs
	end

	def method_missing(*args, &block)
		tries = 0
		begin
			if !@connection
				raise ReconnectNeeded
			end
			@connection.send(*args, &block)
		rescue IOError, ReconnectNeeded
			if tries == 0
				tries += 1
				reconnect
				retry
			else
				raise
			end
		end
	end
end

class Net::IMAP::Address
	def to_s
		if name
			"#{name} <#{mailbox}@#{host}>"
		else
			"#{mailbox}@#{host}"
		end	
	end

	def self.parse address
		if /(.*) <(.*)@(.*)>/ === address
			self.new $1, nil, $2, $3
		elsif /(.*)@(.*) \((.*)\)/ === address
			self.new $3, nil, $1, $2
		else
			parts = address.split('@')
			self.new nil, nil, parts[0], parts[1]
		end
	end

	def email
		"#{mailbox}@#{host}"
	end
end

Camping.goes :CampingAtMailbox
module CampingAtMailbox
	include Camping::Session

	Flagnames = { :Seen => 'read', :Answered => 'replied to' }
	Filetypes = { 'js' => 'text/javascript', 'css' => 'text/css' }

	module Helpers
		def imap
			if @state['imapconnection'] and !residentsession[:imap]
				residentsession[:imap] = @state['imapconnection'].dup
			end
			residentsession[:imap]
		end

		def ldap
			residentsession[:ldap]
		end

		def ldap_base
			$config['ldapbase'].gsub('%{domain}', @state['domain'].split('.').map { |e| "dc=#{e}" }.join(','))
		end

		def composing_messages(k)
			if !residentsession[:composing_messages]
				residentsession[:composing_messages] = Hash.new 
			end
			if residentsession[:composing_messages][k]
				residentsession[:composing_messages][k]
			else
				residentsession[:composing_messages][k] = Models::Message.new
			end
		end

		def finish_message(k)
			residentsession[:composing_messages][k] = nil
		end

		def setup_pager
			if @input.page.to_i > 0 
				@page = @input.page.to_i
				@start = (@page - 1) * 25
				@fin = if @page * 25 > @total then @total else @page * 25 end
			else
				@page = 1
				@start = 0
				@fin = if @total > 25
					25
				else
					@total
				end
			end
		end

		def decode_header(h)
			h.gsub(/=\?([^[:space:]]*?)\?([^[:space:]]*?)\?([^[:space:]]*?)\?=/) do |m|
				charset = $1
				enc = $2
				value = $3
				if enc.downcase == 'q'
					value = value.unpack('M').first
				elsif enc.downcase == 'b'
					value = value.unpack('m').first
				else
					return h
				end
				begin
					if charset.downcase != 'utf-8'
						value = Iconv.new('utf-8', charset).iconv(value)
					end
				rescue Iconv::IllegalSequence
					return h
				end
				value
			end
		end

		def new_messageid
			Time.now.to_i.to_s + '-' + Process.pid.to_s
		end

		def serve(file)
			extension = file.split('.').last
			@headers['Content-Type'] = Filetypes[extension] || 'text/plain'
			@headers['Last-Modified'] = File.stat(file).mtime.rfc2822
			@body = File.read(file)
		end

		def fetch_body_quoted
			part = if @structure.respond_to? :parts and @structure.parts
				@structure.parts.sort_by { |part| 
					[
						if part.media_type == 'TEXT': 0 else 1 end,
						case part.media_type
						when 'PLAIN': 0 
						when 'HTML': 1
						else 2
						end
					]
				}.first
			else
				@structure
			end
			@cmessage.body = WordWrapper.wrap(decode(part)).gsub(/^/, '> ')
		end

		def fetch_addresses(pattern = nil)
			@addresses = []
			if pattern
				st = ('SELECT name, address FROM addresses WHERE user_id = ? AND (name like ? OR address like ?) ORDER BY name, address')
			rh = $db.execute(st, @state['from'].email)
				rh = $db.execute(st, @state['from'].email, "#{pattern}%", "#{pattern}%")
			else
				st = ('SELECT name, address FROM addresses WHERE user_id = ? ORDER BY name, address')
				rh = $db.execute(st, @state['from'].email)
			end
			rh.fetch do |name,address|
				@addresses << [name,address]
			end

			if ldap and pattern and pattern.length > 2
				name_attr = $config['ldapnameattr'] || 'cn'
				mail_attr = $config['ldapmailattr'] || 'mail'
				ldap_search = ($config['ldapsearch'] || [name_attr]).map do |a|
					"(#{a}=#{@pattern}*)"
				end.join('|')
				ldap.search(:base => ldap_base, :filter => ldap_search).each do |ent|
					@addresses << [ent[name_attr][0], ent[mail_attr][0]]
				end
				@addresses.sort! { |a,b| a[0] <=> b[0] }
			end
		end

		def select_mailbox(mb)
			imap.noop
			if residentsession[:selectedmbox] != mb
				imap.select(mb)
				residentsession[:selectedmbox] = mb
				residentsession.delete :uidlist
			end
		end

		def envelope
			@message.attr['ENVELOPE']
		end

		def residentsession
			$residentsession[@cookies.camping_sid]
		end

		def imap_response_handler(resp)
			case resp
			when Net::IMAP::UntaggedResponse
				case resp.name
				# FIXME: update the uidlist, rather than invalidating it. Easier
				# said than done, considering that the server knows the order 
				# and we don't based on resp.
				when 'EXISTS'
					residentsession.delete :uidlist
				when 'EXPUNGE'
					residentsession.delete :uidlist
				end
			end
		end

		def decode(structure)
			# FIXME: handle multipart messages way better than this.
			if !structure.respond_to? :encoding
				return @parts[structure.part_id]
			end
			case structure.encoding
			when 'BASE64'
				@parts[structure.part_id].unpack('m*').first
			when 'QUOTED-PRINTABLE'
				@parts[structure.part_id].gsub(/\r\n/, "\n").unpack('M*').first
			else @parts[structure.part_id]
			end
		end
		
		def get_mailbox_list
			@mailboxes = imap.lsub('', '*')
			 if !@mailboxes
				@error = 'You have no mailboxes subscribed, showing everything'
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

		def output_message_to(out)
			out.puts "From: #{@state['from']}"
			out.puts "To: #{@cmessage.to}"
			out.puts "CC: #{@cmessage.cc}"
			out.puts "Subject: #{@cmessage.subject}"
			out.puts "Date: #{Time.now.rfc822}"
			if @cmessage.attachments.size == 0
				out.puts "Content-Type: text/plain; charset=UTF-8"
				out.puts ""
				out.puts "#{@cmessage.body}"
			else
				boundary = "=_#{Time.now.to_i.to_s}"
				out.puts 'Content-Type: multipart/mixed; boundary="'+boundary+'"'
				out.puts ''
				out.puts %{This is a MIME-formatted email message.}
				out.puts ''
				out.puts "--#{boundary}"
				out.puts "Content-type: text/plain; charset=UTF-8"
				out.puts "Content-transfer-encoding: quoted-printable"
				out.puts ""
				out.puts [@cmessage.body].pack('M')
				out.puts ""
				@cmessage.attachments.each do |att|
					out.puts "--#{boundary}"
					out.puts "Content-Type: #{att['type']}"
					out.puts "Content-Disposition: attachment; filename=\"#{att['filename']}\""
					att['tempfile'].seek(0)
					if /^text/ === att['type']
						out.puts "Content-transfer-encoding: quoted-printable"
						out.puts ""
						att['tempfile'].each_line do |l|
							out.puts [l].pack("M")
						end
						out.puts ""
					else
						out.puts "Content-transfer-encoding: base64"
						out.puts ""
						until att['tempfile'].eof?
							out << [att['tempfile'].read(4500)].pack("m").gsub("\n", "\r\n")
						end
						out.puts ""
					end
				end
				out.puts "--#{boundary}--"
			end
		end
		
		def Pager(controller, current, total, n, *args)
			pages = (total) / n + ((total)  % n == 0 ? 0 : 1)
			prior = current - 1
			nxt = current + 1
			p "Page #{current} of #{pages}"
			p.controls do
				if prior > 0
					a("Previous #{n}", :href => R(controller, *args) << "?page=#{prior}")
				end
				if nxt <= pages
					a("Next #{n}", :href => R(controller, *args) << "?page=#{nxt}")
				end
			end
			return
			p do
				(1..pages).map do |page|
					if page == current
						text page
					else
						a(page, :href => R(controller, *args) << "?page=#{page}")
					end
				end
			end if pages > 1
		end
	end

	module Controllers
		class Index < R '/'
			def get
				if imap and !imap.disconnected?
					redirect Mailboxes
				else
					redirect Login
				end
			end
		end

		# You see a locked door.
		#
		class Login < R '/login'
			
			# The key opens the door. You slip inside. 
			# 
			# See Mailboxes
			def post
				if /@/ === input.username
					@state['domain'] = input.username.split('@').last
					@state['from'] = Net::IMAP::Address.parse(input.username)
				else
					@state['domain'] = env['HTTP_HOST'].split(':').first.gsub(/^(web)?mail\./, '')
					@state['from'] = Net::IMAP::Address.parse(input.username + '@' + @state['domain'])
				end
				imap_connection = ReconnectingIMAP.new(
					($config['imaphost'] || input.imaphost).gsub('%{domain}', @state['domain']), 
					($config['imapport'] || 143).to_i,
					($config['imapssl'] || false)
				)
				caps = imap_connection.capability
				begin
					if caps.include? 'AUTH=LOGIN'
						imap_connection.authenticate('LOGIN', input.username, input.password)
					else
						imap_connection.login(input.username, input.password)
					end
					residentsession.clear
					residentsession[:imap] = imap_connection
					if $config['ldaphost']
						residentsession[:ldap] = Net::LDAP.new(
							:host => $config['ldaphost'].gsub('%{domain}', @state['domain']),
							:port => $config['ldapport'] || 389
						)
						ldap_filter = "(#{$config['ldaprdnattr'] || 'dn'}=#{input.username})"
						mail_attr = $config['ldapmailattr'] || 'mail'
						name_attr = $config['ldapnameattr'] || 'cn'
						ldap.search(:base => ldap_base, :filter => ldap_filter) do |ent|
							@state['from'] = if ent[name_attr]
								Net::IMAP::Address.parse("#{ent[name_attr][0]} <#{ent[mail_attr][0]}>")
							else
								Net::IMAP::Address.parse("#{ent[mail_attr][0]}")
							end
						end
					end
					residentsession[:pinger] = Thread.new do 
						while residentsession[:imap] and !imap.disconnected?
							imap.noop
							sleep 60
						end
					end
					@state['username'] = input.username
					@state['password'] = input.password
					imap.add_response_handler { |r| imap_response_handler(r) }
					begin
						imap.subscribe('INBOX')
						imap.create("Drafts")
						imap.subscribe("Drafts")
						imap.create("Sent")
						imap.subscribe("Sent")
					rescue Net::IMAP::NoResponseError => e
					end

					t = imap.dup
					t.send(:instance_variable_set, :@connection, nil)
					@state['imapconnection'] = t
					residentsession[:usesort] = if caps.include? "SORT": true else false end
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
		class Mailbox < R '/mailboxes/(.+)/'
			
			# Suddenly, there's a whizthunk! and you see an arrow embed itself 
			# in the wall next to your head. There seems to be a Message attached.
			#
			def get(mb)
				@mailbox = mb
				@class = Mailbox
				select_mailbox(mb)
				if !residentsession[:uidlist]
					if residentsession[:usesort]
						residentsession[:uidlist] = imap.uid_sort(['REVERSE', 'ARRIVAL'], 'UNDELETED', 'UTF-8')
					else
						residentsession[:uidlist] = imap.uid_search('UNDELETED')
					end
				end
				@total = residentsession[:uidlist].length
				setup_pager
				if @total > 0 
					# UGLY
					@messageset = residentsession[:uidlist][@start..@fin]
					@messages = imap.uid_fetch(@messageset, ['FLAGS', 'ENVELOPE', 'UID'])
					if residentsession[:usesort]
						@messages = @messages.sort_by { |e| @messageset.index(e.attr['UID']) }
					end
				end
				render :mailbox
			end

			def post(mailbox)
				if input.action =~ /Delete/
					if Array === input.message
						@messages = input.message
					else
						@messages = [input.message]
					end
				end
				@input = imap.uid_store(@messages.map { |e| e.to_i }, '+FLAGS', [:Deleted])
				if residentsession[:uidlist]
					@messages.each do |e|
						residentsession[:uidlist].delete(e.to_i)
					end
				end
				
				redirect R(Mailbox, mailbox)
			end
		end

		# A snappily dressed mailman stands over a postal scale in the front
		# lobby.
		#
		class Style < R '/(.*).css'
			def get(file)
				serve file+'.css'
			end
		end

		class Scripts < R '/(.*).js'
			def get(file)
				serve file+'.js'
			end
		end

		class Logout < R '/logout'
			def get
				imap.disconnect
				residentsession[:imap] = nil
				@state['username'] = nil
				@state['password'] = nil
				redirect R(Login)
			end
		end

		# There is a scroll tacked to the wall with an arrow. You take it 
		# down and read it.
		#
		class Message < R '/mailboxes/(.*)/m(\d+)'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				select_mailbox(mailbox)
				fetch_structure
				render :message
			end
		end
		
		# An inner piece of parchment flutters to the ground as you unroll
		# the scroll. You pick it up and read it.
		#
		class MessagePart < R '/mailboxes/(.*)/m(\d+)/part(.*)'
			def get(mailbox, uid, part)
				@mailbox = mailbox
				@uid = uid.to_i
				select_mailbox(mailbox)
				fetch_structure
				@part = @structureindex[part]
				case @part
				when Net::IMAP::BodyTypeMultipart
					render :messagepart
				when Net::IMAP::BodyTypeMessage
					render :messagepart
				else
					@headers['Content-Type'] = @part.media_type.downcase << '/' << @part.subtype.downcase
					@body = decode(@part)
				end
			end
		end
		
		# There seems to be another object tied to the arrow.
		#
		class Attachment < R '/mailboxes/(.*)/m(\d+)/attachment/(.*)'
			def get(mailbox, uid, part)
				@mailbox = mailbox
				@uid = uid.to_i
				@part = part
				select_mailbox(mailbox)
				fetch_structure
				render :attachment
			end
		end

		# You examine the scroll and arrow for signs of its origin.
		#
		class Header < R '/mailboxes/(.*)/m(\d+)/headers'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				select_mailbox(mailbox)
				@header = imap.uid_fetch(@uid, ['RFC822.HEADER'])[0].attr['RFC822.HEADER']
				render :header
			end
		end

		# There is a large, red button here. 
		#
		class DeleteMessage < R '/mailboxes/(.*)/m(\d+)/delete'

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
					residentsession[:uidlist].delete(@uid)
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
		class MoveMessage < R '/mailboxes/(.*)/m(\d+)/move'
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
				residentsession[:uidlist].delete(@uid)
				redirect Mailbox, mailbox
			end
		end

		# You'll have to write their mother a note.
		#
		class Compose < R('/compose/(.*)')
			def get(messageid)
				if messageid.empty?
					messageid = new_messageid
				end
				@messageid = messageid
				@cmessage = composing_messages(messageid)
				if (!@cmessage.to or @cmessage.to.empty?) and @input.to
					@cmessage.to = @input.to
				end
				render :compose
			end
			def post(messageid)
				select_mailbox("Drafts")
				@messageid = new_messageid
				@uid = input.uid.to_i
				fetch_structure
				@cmessage = composing_messages(@messageid)
				part = if @structure.respond_to? :parts and @structure.parts
					@structure.parts.sort_by { |part| 
						[
							if part.media_type == 'TEXT': 0 else 1 end,
							case part.media_type
							when 'PLAIN': 0 
							when 'HTML': 1
							else 2
							end
						]
					}.first
				else
					@structure
				end
				@cmessage.body = WordWrapper.wrap(imap.uid_fetch(@uid, "BODY[#{part.part_id}]").first.attr["BODY[#{part.part_id}]"])
				@cmessage.subject = envelope.subject if envelope.subject
				@cmessage.to = envelope.to.map { |e| e.to_s }.join(', ') if envelope.to
				@cmessage.cc = envelope.cc.map { |e| e.to_s }.join(', ') if envelope.cc
				@cmessage.bcc = envelope.bcc.map { |e| e.to_s }.join(', ') if envelope.bcc
				# FIXME: handle attachments
				redirect R(Compose, @messageid)
			end
		end

		class Search < R '/search/([^/]*)'
			def post(mailbox)
				@mailbox = mailbox
				select_mailbox(@mailbox)
				uids = imap.uid_search(input.search.split(/\s+/).map { |e| ['OR', 'BODY', e, 'SUBJECT', e, 'FROM', e] }.flatten + ['UNDELETED'])
				if !uids.empty?
					@search_id = new_messageid
					(residentsession[:searchresults] ||= Hash.new)[@search_id] = uids
					(residentsession[:searchmailboxes] ||= Hash.new)[@search_id] = @mailbox
					redirect R(SearchResults, @search_id)
				else
					render :no_results
				end
			end
		end

		class Purge < R '/purge/(.*)'
			def get(mailbox)
				@mailbox= mailbox
				render :purgeconfirm
			end
			def post(mailbox)
				select_mailbox(mailbox)
				imap.expunge
				redirect R(Mailbox, mailbox)
			end
		end

		class SearchResults < R '/search/result/(.*)'
			def get(search_id)
				@class = SearchResults
				@search_id = search_id
				@results = residentsession[:searchresults][@search_id]
				@mailbox = residentsession[:searchmailboxes][@search_id]
				@total = @results.length
				setup_pager
				@messages = imap.uid_fetch(@results[@start..@fin], ['FLAGS', 'ENVELOPE', 'UID'])
				render :mailbox
			end
		end

		class Reply < R '/mailboxes/(.*)/m(\d+)/reply(.*)'
			def get(mailbox, uid, mode)
				@mailbox = mailbox
				@uid = uid.to_i
				@messageid = new_messageid
				@cmessage = composing_messages(@messageid)
				select_mailbox(mailbox)
				fetch_structure
				fetch_body_quoted

				recips = if @message.attr['ENVELOPE'].reply_to.empty? 
					envelope.from 
				else
					envelope.reply_to 
				end
	
				if mode == 'all'
					if envelope.to
						recips += envelope.to 
					end
					if envelope.cc
						recips += envelope.cc 
					end
					if envelope.bcc
						recips += envelope.bcc 
					end
					recips.uniq!
				end

				@cmessage.to = recips.select { |e| e.email != @state['from'].email }.join(', ')
				@cmessage.subject = 'Re: ' << decode_header(@message.attr['ENVELOPE'].subject || '')
				render :compose
			end
		end

		class Forward < R '/mailboxes/(.*)/m(\d+)/forward'
			def get(mailbox, uid)
				@mailbox = mailbox
				@uid = uid.to_i
				@messageid = Time.now.to_i.to_s + '-' + Process.pid.to_s
				@cmessage = composing_messages(@messageid)
				select_mailbox(mailbox)
				fetch_structure
				fetch_body_quoted
				@cmessage.subject = 'Fw: ' << decode_header(@message.attr['ENVELOPE'].subject || '')
				render :compose
			end
		end

		class CreateMailbox < R '/newmailbox'
			def get
				render :createmailbox
			end

			def post
				@mailbox = input.mailbox
				begin
					imap.create(input.mailbox)
					imap.subscribe(input.mailbox)
				rescue Net::IMAP::NoResponseError => @error
					render :createmailbox
				else
					redirect R(Mailboxes)
				end
			end
		end

		class AttachFile < R('/attach/(.*)')
			def get(messageid)
				@messageid = messageid
				@cmessage = composing_messages(@messageid)
				render :attach_files
			end
		end

		class Send < R('/send/(.*)')
			def post(messageid)
				@messageid = messageid
				@cmessage = composing_messages(@messageid)
				if input.to
					@cmessage.to = input.to 
				end
				if input.cc
					@cmessage.cc = input.cc 
				end
				if input.bcc
					@cmessage.bcc = input.bcc 
				end
				if input.subject
					@cmessage.subject = input.subject 
				end
				if input.body
					@cmessage.body = input.body
				end
				if input.file and input.file.is_a? H
					@cmessage.attachments << input.file
					input.file.unlink # UNIX only
				end

				if /^Attach/ === input.action 
					redirect R(AttachFile, messageid)
					#render :attach_files
				elsif /^Save/ === input.action
					m = ''
					o = StringIO.new(m)
					output_message_to(o)
					imap.append("Drafts", m)
					redirect R(Mailbox, 'Drafts')
				else			
					connect_params = [
						$config['smtphost'].gsub('%{domain}', @state['domain']), 
						$config['smtpport'].to_i,
						env['HTTP_HOST'].split(':').first
					]
					if $config['smtpauth']
						connect_params += [@state['username'], @state['password'], :plain]
					end
					Net::SMTP.start(*connect_params) do |smtp|
						recips = [@cmessage.to, @cmessage.cc, @cmessage.bcc].join(',').split(',').select {|e| !e.strip.empty? }.map do |a| 
							Net::IMAP::Address.parse(a.strip).email 
						end
						@results = smtp.open_message_stream(@state['from'].email, recips) do |out|
							output_message_to(out)
							msg = ''
							# FIXME, big attachments should totally cause huge core growth
							o = StringIO.new(msg)
							output_message_to(o)
							imap.append("Sent", msg, [:Seen], Time.now)
						end
						@cmessage = nil
						finish_message(@messageid)
					end
				
					render :sent
				end
			end
		end

		class Test < R '/test'
			def get
				raise 'hell'
			end
		end

		class ServerError
			def get(k,m,e)
				@status = 500
				IO.popen("mail #{$config['erroremail']} -s CATM-Error", 'w') do |err|
					err.puts "Error in #{k}.#{m}; #{e.class} #{e.message}:"
					e.backtrace.each do |bt|
						err.puts bt
					end
				end

				div do
				 	h1 'Internal Mail System Error'
					p { "The error message has been sent off for inspection -- this really shouldn't happen. Sorry about that!" }
				end

     	end
		end


		class Addresses < R '/addresses'
			def get
				fetch_addresses
				@errors = []
				render :addresses
			end

			def post
				@errors = []
				fetch_addresses
				if /@/ === input.address
					$db.execute("INSERT INTO addresses (name, address, user_id) VALUES (?, ?, ?)", input.name, input.address, @state['from'].email)
					redirect R(Addresses)
				else
					@errors << "That didn't look like an email address -- it's gotta at least have an @"
					render :addresses
				end
			end
			
		end

		class AddressesAutocomplete < R '/addresses/autocomplete'
			def post
				@pattern = input.to || input.cc
				fetch_addresses(@pattern)

				@addresses = @addresses.select { |e| /^#{@pattern}/i === e[0] }

				render :_addresses
			end
		end

		class DeleteAddress < R '/addresses/delete/(.*)'
			def get(address)
				@address = address
				render :deleteaddressq
			end

			def post(address)
				$db.do("DELETE FROM addresses WHERE user_id = ? AND address = ?", @state['from'].email, address)
				redirect R(Addresses)
			end
		end

	end

	module Models
		class Message
			attr_accessor :to, :cc, :bcc, :subject, :body
			attr_reader :attachments
			def initialize
				@attachments = []
				@to = ''
				@cc = ''
				@bcc = ''
				@subject = ''
				@body = ''
			end
			def inspect
				"Messsage to #{to}, subject #{subject}, body is #{body.size} bytes, and #{attachments.length} attachment(s)"
			end
		end
	end

	module Views
		def addresses
			h1 'Addresses'
			table.addresses do
				tr { th 'Name'; th 'Address' }
				@addresses.each do |name,address|
					tr do
						td name
						td address
						td do
							a('delete', :href => R(DeleteAddress, address))
							a('compose', :href => R(Compose, nil, {:to => "#{name} <#{address}>"}))
						end 
					end
				end
			
				@errors.each do |e|
					tr.error { td(:colspan => 2) { e } }
				end

				form :action => R(Addresses), :method => 'post' do
					tr do
						td { input :name => 'name', :type => 'text' }
						td { input :name => 'address', :type => 'text' }
						td { input :type => 'submit', :value => 'Add' }
					end
				end
			end
		end

		def _addresses
			ul do
				@addresses.each do |e|
					li(if e[0] then "#{e[0]} <#{e[1]}>" else e[1] end)
				end
			end
		end

		def layout
			html do
				head do
					title 'Webmail'
					link :rel => 'stylesheet', :type => 'text/css', 
							:href => R(Style, 'functional')
					link :rel => 'stylesheet', :type => 'text/css', 
							:href => R(Style, 'site')
					script :src => R(Scripts, 'prototype'), :type => 'text/javascript'
					script :src => R(Scripts, 'scriptaculous'), :type => 'text/javascript'
					script :src => R(Scripts, 'behaviour'), :type => 'text/javascript'
					script :src => R(Scripts, 'site'), :type => 'text/javascript'
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
			p begin File.read('banner') rescue $config['banner'] end
			form :action => R(Login), :method => 'post' do
				label 'Email Address', :for => 'username'; br
				input :name => 'username', :type => 'text'; br

				label 'Password', :for => 'password'; br
				input :name => 'password', :type => 'password'; br

				if !$config['imaphost']
					label 'Mail Server', :for => 'imaphost'; br
					input :name => 'imaphost', :type => 'text'; br
				end

				input :type => 'submit', :name => 'login', :value => 'Login'
			end
		end

		def createmailbox
			form :action => R(CreateMailbox), :method => 'post' do
				p 'Enter the name of the mailbox you want to create'
				input :type => 'text', :name => 'mailbox', :value => @mailbox
				input :type => 'submit', :value => 'Create'
			end
		end
	
		def deleteq
			form :action => R(DeleteMessage, @mailbox, @uid), :method => 'post' do
				p 'Are you sure you want to delete this message?'
				input :type => 'hidden', :name => 'deletemessage', :value => @uid
				input :type => 'submit', :value => 'Confirm'
			end
		end

		def deleteaddressq
			form :action => R(DeleteAddress, @address), :method => 'post' do
				p "Are you sure you want to delete #{@address} from your address book?"
				input :type => 'hidden', :name => 'deletemessage', :value => @uid
				input :type => 'submit', :value => 'Confirm'
			end
		end

		def movemessage
			form :action => R(MoveMessage, @mailbox, @uid), :method => 'post' do
				ul.folderlist do
					@mailboxes.each do |mb|
						li do 
							label do
								input :type => 'radio', :name => 'folder', :value => mb.name
								text mb.name
							end
						end
					end
				end
				input :type => 'submit', :value => 'Move message'
			end
		end

		def mailboxes
			p.controls do
				a('Compose a Message', :href => R(Compose, nil))
				a('Create Mailbox', :href => R(CreateMailbox)) 
				a('Address Book', :href => R(Addresses))
				a('Log Out', :href => R(Logout))
			end
			h1 "Mailboxes"
			ul do
				@mailboxes.each do |mb|
					li do
						a(mb.name, :href => R(Mailbox, mb.name))
					end
				end
			end
		end

		def searchresults
			@results.each do |uid|
				p uid
			end
		end

		def mailbox
			form :action => R(Search, @mailbox), :method => 'post' do 
				p.controls do
					a('Compose a Message', :href => R(Compose, nil))
					a('Mailbox List', :href => R(Mailboxes))
					a('Address Book', :href => R(Addresses))
					a('Purge Deleted Messages', :href => R(Purge, @mailbox))
					a('Log Out', :href => R(Logout))
					label.search { text "Search "; input.search :name=>'search', :type=>'text' }
				end
			end
			h1 "#{@mailbox} (#{@total} total)"
			if @total == 0
				p "No messages"
				return
			end
			form(:action => R(Mailbox, @mailbox), :method => 'post') do
				table do
					@messages.each do |message|
						env = message.attr['ENVELOPE']
						flags = message.attr['FLAGS']
						tr(:class => 'header') do
							td(:class => if flags.include? :Seen then 'seen' else 'unseen' end) do
								p.envelope do 
									input.controls :type=>'checkbox', :value=> message.attr['UID'], :name=>'message'
									if @mailbox == 'Drafts' and env.to
										text 'To ' 
										text env.to[0..8].map { |to|
											capture do
												cite(:title => to.mailbox + '@' + to.host) do
													decode_header(to.name || to.mailbox)
												end 
											end
										}.join(', ')
										if env.to.length > 9
											text ", more..."
										end
										br
									end
									text 'From ' 
									cite(:title => env.from[0].mailbox || 'invalid address' + '@' + env.from[0].host || 'invalid host') do
										decode_header(env.from[0].name || env.from[0].mailbox || 'invalid mailbox')
									end if env.from
									span(:class => 'date') {
										if env.date
											Time.parse(env.date).strftime('on %Y/%m/%d at %H:%M') rescue 'Invalid date/time'
										else
											'(no date)'
										end
									}
									if !flags.empty? then
										flags.map { |e| Flagnames[e] }.join(', ')
									end
								end
								p.subject do
									a(if !env.subject or env.subject.strip.empty? then 'no subject' else decode_header(env.subject) end, :href => R(Message, @mailbox, message.attr['UID']))
								end 
							end
							if @mailbox == 'Drafts'
								td do
									form :action => R(Compose, nil), :method => 'post' do
										input :type => 'hidden', :name => 'uid', :value => message.attr['UID']
										input :type => 'submit', :value => "Edit"
									end
								end
							end
						end
					end
				end
				p.controls :id=>'selected_message_controls' do
					input :type=>'submit', :name => 'action', :value => 'Delete Selected'
				end
			end
			Pager(@class, @page, @total, 25, if @class == Mailbox: @mailbox else @search_id end)
		end

		def _messageheader(envelope, controls = false)
			div.header do 
				p do 
					text "From " 
					envelope.from.each do |f|
						cite(:title => f.mailbox + '@' + f.host) { decode_header(f.name || f.mailbox) }
					end
					text (Time.parse(envelope.date).strftime('on %Y/%m/%d at %H:%M') || 'none') if envelope.date
				end if envelope.from
				p do
					begin
						text "To "
						envelope.to.each do |t|
							cite(:title => t.mailbox + '@' + t.host) { decode_header(t.name || t.mailbox) }
						end
					rescue
					end
				end if envelope.to
				p do
					begin
						text "Carbon copies to "
						envelope.cc.each do |t|
							cite(:title => t.mailbox + '@' + t.host) { decode_header(t.name || t.mailbox) }
						end
					rescue
					end
				end if envelope.cc
				p do
					begin
						text "Reply to "
						envelope.reply_to.each do |t|
							cite(:title => t.mailbox + '@' + t.host) { decode_header(t.name || t.mailbox) }
						end
					rescue
					end
				end if envelope.reply_to and envelope.reply_to != envelope.from
				p do
					begin
						text "Also copies to "
						envelope.bcc.each do |t|
							cite(:title => t.mailbox + '@' + t.host) { decode_header(t.name || t.mailbox) }
						end
					rescue
					end
				end if envelope.bcc
				p.subject decode_header(envelope.subject) if envelope.subject
				_messagecontrols([envelope.to, envelope.cc, envelope.bcc, envelope.reply_to, envelope.from].flatten.select { |e| e and e.email != @state['from'].email }.uniq.size > 1)

			end
		end

		def message	
			_messageheader(envelope, true)
			_message(@structure)
			p.fin '❧'
		end

		def _messagecontrols(multiple_recipients = false)
			p.controls do
				a 'reply', :href => R(Reply, @mailbox, uid, nil)
				if multiple_recipients
					a '(to all)', :href => R(Reply, @mailbox, uid, 'all')
				end
				a 'forward', :href => R(Forward, @mailbox, uid)
				a 'delete', :href => R(DeleteMessage, @mailbox, uid)
				a 'move', :href => R(MoveMessage, @mailbox, uid)
				a 'headers', :href => R(Header, @mailbox, uid)
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
				part = decode(structure)
				if structure.param['CHARSET'] and structure.param['CHARSET'].downcase != 'utf-8'
					begin
						part = Iconv.new('utf-8', structure.param['CHARSET'].downcase).iconv(part)
					rescue Iconv::IllegalSequence
						part
					end
				end
				case structure.subtype
				when 'PLAIN'
					pre do
						capture { WordWrapper.wrap(part).gsub(%r{(https?://[^[:space:]]+)}) { |m| "<a href='#{$1}' target='_new'>#{$1}</a>" } }
					end
				when 'HTML'
					div.htmlmessage do
						capture do
							if b = Hpricot(part, :fixup_tags => true).at('body')
								b.stag.name = 'div'
								b.etag = Hpricot::ETag.new('div')
								b
							else
								Hpricot(part, :fixup_tags => true)
							end
						end
					end
				else
					pre do
						capture { WordWrapper.wrap(part).gsub(%r{(http://[^[:space:]]+)}) { |m| "<a href='#{$1}' target='_new'>#{$1}</a>" } }
					end
				end
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

		def purgeconfirm
			form :action => R(Purge, @mailbox), :method => 'post' do
				p 'Are you sure you want to delete this message?'
				input :type => 'submit', :value => 'Confirm'
			end
		end	

		def sent
			p.controls do
				a('Compose a Message', :href => R(Compose, nil))
				a('Create Mailbox', :href => R(CreateMailbox)) 
				a('Address Book', :href => R(Addresses))
				a('Log Out', :href => R(Logout))
			end
			h1 'Your mail was sent'
			@results.each do |r|
				p r
			end

			p { a('Continue', :href => R(Mailbox, 'INBOX')) }
		end

		def messagepart
			_messagepartheader @part if Net::IMAP::BodyTypeMessage === @part
			_message @part
		end

		def attachment
			p @part.inspect
		end

		def compose
			form.compose :action => R(Send, @messageid), :method => 'post', :enctype => 'multipart/form-data' do
				p do
					label { text 'To '; input :type=> 'text', :name => 'to', :id => 'to', :value => @cmessage.to }
					div.autocomplete :id => 'to_autocomplete' do end
					script { text %{new Ajax.Autocompleter("to", "to_autocomplete", "#{self / R(AddressesAutocomplete)}", { tokens: ',' }); } }
				end
				p do
					label { text 'CC '; input :type=> 'text', :name => 'cc', :id => 'cc', :value => @cmessage.cc }
					div.autocomplete :id => 'cc_autocomplete' do end
					script { text %{new Ajax.Autocompleter("cc", "cc_autocomplete", "#{self / R(AddressesAutocomplete)}", { tokens: ',' }); } }
				end
				p do
					label { text 'BCC '; input :type=> 'text', :name => 'bcc', :id => 'bcc', :value => @cmessage.bcc }
					div.autocomplete :id => 'bcc_autocomplete' do end
					script { text %{new Ajax.Autocompleter("bcc", "bcc_autocomplete", "#{self / R(AddressesAutocomplete)}", { tokens: ',' }); } }
				end
				p do
					label { text 'Subject '; input :type=> 'text', :name => 'subject', :value => @cmessage.subject } 
				end
				p do
					label { text 'Body '; textarea.body(:name => 'body') { text @cmessage.body } }
				end
				p do
					input :type => 'submit', :name => 'action', :value => 'Send' 
					input :type => 'submit', :name => 'action', :value => 'Attach Files' 
					input :type => 'submit', :name => 'action', :value => 'Save to Drafts' 
				end
			end
		end

		def attach_files
			p @cmessage.inspect
			form.compose :action => R(Send, @messageid), :method => 'post', :enctype => 'multipart/form-data' do
				p { input :type => 'file', :name => 'file' }
				p do
					input :type => 'submit', :name => 'action', :value => 'Send' 
					input :type => 'submit', :name => 'action', :value => 'Attach More Files' 
				end
			end
		end

		def no_results
			p 'Nothing found'
		end
		
		def showinput
			p @input.inspect
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

Dir.chdir(File.dirname(__FILE__))
$config = YAML.load(File.read('mailbox.conf'))
$db = DBI.connect($config['database'])
$cleanup = Thread.new { GC.start; sleep 60 } if not $cleanup
if $config['ldaphost']
	require 'net/ldap'
end
if $config['smtptls']
	require 'net/smtp_tls'
end

if __FILE__ == $0
	params = $config['database'].split(':', 3)
	CampingAtMailbox::Models::Base.establish_connection :adapter => params[1].downcase, :database => params[2]
	require 'camping/fastcgi'
	Camping::FastCGI.start(CampingAtMailbox)
end
