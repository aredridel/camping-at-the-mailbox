$LOAD_PATH.unshift 'app'
$LOAD_PATH.unshift 'lib'

require 'campingatmailbox'
require 'rack/session/redis'
require 'dbi'

use Rack::Session::Redis, url: "redis://localhost:6379/0", namespace: "rack:session", expire_after: 604800
use Rack::ShowExceptions

$config = YAML.load(File.read('mailbox.conf'))
$db = DBI.connect($config['database'])
$cleanup = Thread.new { GC.start; sleep 60 } if not $cleanup
if $config['ldaphost']
	require 'net/ldap'
end
if $config['smtptls']
	require 'net/smtp_tls'
end

params = $config['database'].split(':', 3)
CampingAtMailbox::Models::Base.establish_connection :adapter => params[1].downcase, :database => params[2]


Dir.chdir(File.dirname(__FILE__))

run CampingAtMailbox
