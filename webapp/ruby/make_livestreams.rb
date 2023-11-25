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

livestreams = db.xquery('SELECT * FROM livestreams').to_a.map do |livestream|
  reactions = db.xquery(
    'SELECT COUNT(*) FROM livestreams l INNER JOIN reactions r ON l.id = r.livestream_id WHERE l.id = ?',
    livestream.fetch(:id), as: :array
  ).first[0]

  total_tips = db.xquery(
    'SELECT IFNULL(SUM(l2.tip), 0) FROM livestreams l INNER JOIN livecomments l2 ON l.id = l2.livestream_id WHERE l.id = ?',
    livestream.fetch(:id),
    as: :array
  ).first[0]

  score = reactions + total_tips

  livestream[:total_reactions] = reactions
  livestream[:total_tips] = total_tips
  livestream[:score] = score

  db.xquery('UPDATE livestreams SET total_reactions = ?, total_tips = ?, score = ? WHERE id = ?', reactions, total_tips, score, livestream.fetch(:id))

  livestream
end

livestreams.sort_by! {|u| u[:score] }
p livestreams.count
