# how to use: $ bundle exec ruby console.rb
require_relative 'app'
require 'irb'

db = Mysql2::Client.new(
  host: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_ADDRESS', '127.0.0.1'),
  port: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PORT', '3306').to_i,
  username: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_USER', 'isucon'),
  password: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PASSWORD', 'isucon'),
  database: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_DATABASE', 'isupipe'),
  symbolize_keys: true,
  cast_booleans: true,
  reconnect: true,
)

binding.irb
