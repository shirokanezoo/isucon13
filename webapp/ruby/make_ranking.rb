require_relative 'app'

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

users = db.xquery('SELECT * FROM users').to_a.map do |user|
  dark_mode = db.xquery('SELECT dark_mode FROM themes WHERE user_id = ?', user.fetch(:id)).first[:dark_mode]

  reactions = db.xquery(<<~SQL, user.fetch(:id), as: :array).first[0]
    SELECT COUNT(*) FROM users u
    INNER JOIN livestreams l ON l.user_id = u.id
    INNER JOIN reactions r ON r.livestream_id = l.id
    WHERE u.id = ?
  SQL

  tips = db.xquery(<<~SQL, user.fetch(:id), as: :array).first[0]
    SELECT IFNULL(SUM(l2.tip), 0) FROM users u
    INNER JOIN livestreams l ON l.user_id = u.id
    INNER JOIN livecomments l2 ON l2.livestream_id = l.id
    WHERE u.id = ?
  SQL

  user[:total_reactions]  = reactions
  user[:total_tips]       = tips
  user[:score]            = reactions + tips
  user[:dark_mode]        = dark_mode == 1

  db.xquery('UPDATE users SET total_reactions = ?, total_tips = ?, score = ?, dark_mode = ? WHERE id = ?', reactions, tips, user.fetch(:score), dark_mode, user.fetch(:id))

  user
end

users.sort_by! {|u| u[:score] }
p users.count
