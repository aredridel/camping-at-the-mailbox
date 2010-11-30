require 'campingatmailbox'

params = $config['database'].split(':', 3)
#CampingAtMailbox::Models::Base.establish_connection :adapter => params[1].downcase, :database => params[2]

use Rack::ShowExceptions

run CampingAtMailbox
