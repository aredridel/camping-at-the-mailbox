$LOAD_PATH.unshift '.'

require 'campingatmailbox'
require 'rack/session/redis'

params = $config['database'].split(':', 3)
#CampingAtMailbox::Models::Base.establish_connection :adapter => params[1].downcase, :database => params[2]

use Rack::Session::Redis
use Rack::ShowExceptions


run CampingAtMailbox
