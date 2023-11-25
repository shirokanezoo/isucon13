# frozen_string_literal: true

require 'base64'
require 'bcrypt'
require 'digest'
require 'mysql2'
require 'mysql2-cs-bind'
require 'open3'
require 'securerandom'
require 'sinatra/base'
require 'sinatra/json'
require 'fileutils'

require_relative 'tags'

WEBAPP_DIR = File.expand_path('..', __dir__)
PUBLIC_DIR = File.expand_path('../public', __dir__)
ICON_BASE_DIR = File.expand_path('../files', __dir__)

ZONE_HEADER = File.read(File.join(__dir__, 'header.zone')).gsub(/<ISUCON_SUBDOMAIN_ADDRESS>/, ENV.fetch('ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS'))
ZONE_FILE = ENV['ISUCON13_ZONE_FILE'] || File.join(File.expand_path('../zones', __dir__), 'u.isucon.dev.zone')

module Isupipe
  class App < Sinatra::Base
    enable :logging
    set :show_exceptions, :after_handler
    set :sessions, domain: 'u.isucon.dev', path: '/', expire_after: 1000*60
    set :session_secret, ENV.fetch('ISUCON13_SESSION_SECRETKEY', 'isucon13_session_cookiestore_defaultsecret').unpack('H*')[0]
    set :public_folder, File.expand_path('../public', __dir__)

    POWERDNS_SUBDOMAIN_ADDRESS = ENV.fetch('ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS')

    DEFAULT_SESSION_ID_KEY = 'SESSIONID'
    DEFAULT_SESSION_EXPIRES_KEY = 'EXPIRES'
    DEFAULT_USER_ID_KEY = 'USERID'
    DEFAULT_USERNAME_KEY = 'USERNAME'

    class HttpError < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        super(message || "HTTP error #{code}")
        @code = code
      end
    end

    error HttpError do
      e = env['sinatra.error']
      status e.code
      json(error: e.message)
    end

    helpers do
      def db_conn
        Thread.current[:db_conn] ||= connect_db
      end

      def connect_db
        Mysql2::Client.new(
          host: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_ADDRESS', '127.0.0.1'),
          port: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PORT', '3306').to_i,
          username: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_USER', 'isucon'),
          password: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PASSWORD', 'isucon'),
          database: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_DATABASE', 'isupipe'),
          symbolize_keys: true,
          cast_booleans: true,
          reconnect: true,
        )
      end

      def db_transaction(&block)
        db_conn.query('BEGIN')
        ok = false
        begin
          retval = block.call(db_conn)
          db_conn.query('COMMIT')
          ok = true
          retval
        ensure
          unless ok
            db_conn.query('ROLLBACK')
          end
        end
      end

      def decode_request_body(data_class)
        body = JSON.parse(request.body.tap(&:rewind).read, symbolize_names: true)
        data_class.new(**data_class.members.map { |key| [key, body[key]] }.to_h)
      end

      def cast_as_integer(str)
        Integer(str, 10)
      rescue
        raise HttpError.new(400)
      end

      def verify_user_session!
        sess = session[DEFAULT_SESSION_ID_KEY]
        unless sess
          raise HttpError.new(403)
        end

        session_expires = sess[DEFAULT_SESSION_EXPIRES_KEY]
        unless session_expires
          raise HttpError.new(403)
        end

        now = Time.now
        if now.to_i > session_expires
          raise HttpError.new(401, 'session has expired')
        end

        nil
      end

      def fill_livestream_response(tx, livestream_model, all_tags: nil)
        owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livestream_model.fetch(:user_id)).first
        owner = fill_user_response(tx, owner_model)

        tags = (all_tags ? all_tags[livestream_model.fetch(:id)] : nil) || tx.xquery('SELECT tag_id FROM livestream_tags WHERE livestream_id = ?', livestream_model.fetch(:id)).map do |livestream_tag_model|
          TAGS_BY_ID[livestream_tag_model.fetch(:tag_id)]
        end

        livestream_model.slice(:id, :title, :description, :playlist_url, :thumbnail_url, :start_at, :end_at).merge(
          owner:,
          tags:,
        )
      end

      def livestream_tags_preload(tx, livestream_models)
        all_tags = tx.xquery('select livestream_tags.livestream_id, livestream_tags.tag_id from livestream_tags where livestream_id in (?)', [livestream_models.map { _1.fetch(:id) }]).to_a.group_by do |row|
          row.fetch(:livestream_id)
        end.transform_values do |vs|
          vs.map { TAGS_BY_ID[_1.fetch(:tag_id)] }
        end
      end

      def fill_livecomment_response(tx, livecomment_model, livestream_model: nil)
        comment_owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livecomment_model.fetch(:user_id)).first
        comment_owner = fill_user_response(tx, comment_owner_model)

        livestream_model = livestream_model || tx.xquery('SELECT * FROM livestreams WHERE id = ?', livecomment_model.fetch(:livestream_id)).first
        livestream = fill_livestream_response(tx, livestream_model)

        livecomment_model.slice(:id, :comment, :tip, :created_at).merge(
          user: comment_owner,
          livestream:,
        )
      end

      def fill_livecomment_report_response(tx, report_model, livecomment_model: nil, livestream_model: nil)
        reporter_model = tx.xquery('SELECT * FROM users WHERE id = ?', report_model.fetch(:user_id)).first
        reporter = fill_user_response(tx, reporter_model)

        livecomment_model = livecomment_model || tx.xquery('SELECT * FROM livecomments WHERE id = ?', report_model.fetch(:livecomment_id)).first
        livecomment = fill_livecomment_response(tx, livecomment_model, livestream_model:)

        report_model.slice(:id, :created_at).merge(
          reporter:,
          livecomment:,
        )
      end

      def fill_reaction_response(tx, reaction_model)
        user_model = tx.xquery('SELECT * FROM users WHERE id = ?', reaction_model.fetch(:user_id)).first
        user = fill_user_response(tx, user_model)

        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', reaction_model.fetch(:livestream_id)).first
        livestream = fill_livestream_response(tx, livestream_model)

        reaction_model.slice(:id, :emoji_name, :created_at).merge(
          user:,
          livestream:,
        )
      end

      def fill_user_response(tx, user_model)
        {
          id: user_model.fetch(:id),
          name: user_model.fetch(:name),
          display_name: user_model.fetch(:display_name),
          description: user_model.fetch(:description),
          theme: {
            id: user_model.fetch(:id),
            dark_mode: user_model.fetch(:dark_mode),
          },
          icon_hash: user_model.fetch(:icon_hash),
        }
      end

      def render_zone_file
        lines = db_conn.xquery('SELECT name FROM users').map do |user|
          "#{user.fetch(:name)} IN A #{POWERDNS_SUBDOMAIN_ADDRESS}"
        end
        "#{ZONE_HEADER}\n#{lines.join(?\n)}\n"
      end
    end

    # 初期化
    post '/api/initialize' do
      out, status = Open3.capture2e('../sql/init.sh')
      unless status.success?
        logger.warn("init.sh failed with out=#{out}")
        halt 500
      end

      # アイコン削除
      FileUtils.rm_rf(ICON_BASE_DIR)
      FileUtils.mkdir_p(ICON_BASE_DIR)

      # zone file
      FileUtils.mkdir_p(File.dirname(ZONE_FILE))
      File.write ZONE_FILE, render_zone_file()
        spawn('nsd-control', 'reload', 'u.isucon.dev')

      # ../default/icons 参照
      # db.xquery('SELECT name FROM users').each do |user|
      #   FileUtils.cp(FALLBACK_IMAGE, File.join(ICON_BASE_DIR, user.fetch(:name)))
      # end

      # 初期状態は全員 FALLBACK_IMAGE がアイコン
      # db.xquery('SELECT name FROM users').each do |user|
      #   FileUtils.cp(FALLBACK_IMAGE, File.join(ICON_BASE_DIR, user.fetch(:name)))
      # end
      # db_conn.xquery('UPDATE users SET icon_hash = ?', Digest::SHA256.hexdigest(File.binread(FALLBACK_IMAGE)))

      json(
        language: 'ruby',
      )
    end

    # top
    get '/api/tag' do
      json(
        tags: TAGS,
      )
    end

    # 配信者のテーマ取得API
    get '/api/user/:username/theme' do
      verify_user_session!

      username = params[:username]

      user_model = db_conn.xquery('SELECT id, dark_mode FROM users WHERE name = ?', username).first
      unless user_model
        raise HttpError.new(404)
      end

      json(
        id: user_model.fetch(:id),
        dark_mode: user_model.fetch(:dark_mode),
      )
    end

    # livestream

    ReserveLivestreamRequest = Data.define(
      :tags,
      :title,
      :description,
      :playlist_url,
      :thumbnail_url,
      :start_at,
      :end_at,
    )

    # reserve livestream
    post '/api/livestream/reservation' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      req = decode_request_body(ReserveLivestreamRequest)

      livestream = db_transaction do |tx|
        # 2023/11/25 10:00からの１年間の期間内であるかチェック
        term_start_at = Time.utc(2023, 11, 25, 1)
        term_end_at = Time.utc(2024, 11, 25, 1)
        reserve_start_at = Time.at(req.start_at, in: 'UTC')
        reserve_end_at = Time.at(req.end_at, in: 'UTC')
        if reserve_start_at >= term_end_at || reserve_end_at <= term_start_at
          raise HttpError.new(400, 'bad reservation time range')
        end

        # 予約枠をみて、予約が可能か調べる
        # NOTE: 並列な予約のoverbooking防止にFOR UPDATEが必要
        tx.xquery('SELECT * FROM reservation_slots WHERE start_at >= ? AND end_at <= ? FOR UPDATE', req.start_at, req.end_at).each do |slot|
          count = tx.xquery('SELECT slot FROM reservation_slots WHERE start_at = ? AND end_at = ?', slot.fetch(:start_at), slot.fetch(:end_at)).first.fetch(:slot)
          logger.info("#{slot.fetch(:start_at)} ~ #{slot.fetch(:end_at)}予約枠の残数 = #{slot.fetch(:slot)}")
          if count < 1
            raise HttpError.new(400, "予約期間 #{term_start_at.to_i} ~ #{term_end_at.to_i}に対して、予約区間 #{req.start_at} ~ #{req.end_at}が予約できません")
          end
        end

        tx.xquery('UPDATE reservation_slots SET slot = slot - 1 WHERE start_at >= ? AND end_at <= ?', req.start_at, req.end_at)
        tx.xquery('INSERT INTO livestreams (user_id, title, description, playlist_url, thumbnail_url, start_at, end_at) VALUES(?, ?, ?, ?, ?, ?, ?)', user_id, req.title, req.description, req.playlist_url, req.thumbnail_url, req.start_at, req.end_at)
        livestream_id = tx.last_id

	# タグ追加
        req.tags.each do |tag_id|
          tx.xquery('INSERT INTO livestream_tags (livestream_id, tag_id) VALUES (?, ?)', livestream_id, tag_id)
        end

        fill_livestream_response(tx, {
          id: livestream_id,
          user_id:,
          title: req.title,
          description: req.description,
          playlist_url: req.playlist_url,
          thumbnail_url: req.thumbnail_url,
          start_at: req.start_at,
          end_at: req.end_at,
        })
      end

      status 201
      json(livestream)
    end

    # list livestream
    get '/api/livestream/search' do
      key_tag_name = params[:tag] || ''

      livestreams = db_transaction do |tx|
        livestream_models =
          if key_tag_name != ''
            # タグによる取得
            tag_id_list = [ TAGS_BY_NAME[key_tag_name].fetch(:id) ].reject(&:nil?)
            tx.xquery('SELECT * FROM livestream_tags WHERE tag_id IN (?) ORDER BY livestream_id DESC', tag_id_list).map do |key_tagged_livestream|
              tx.xquery('SELECT * FROM livestreams WHERE id = ?', key_tagged_livestream.fetch(:livestream_id)).first
            end
          else
            # 検索条件なし
            query = 'SELECT * FROM livestreams ORDER BY id DESC'
            limit_str = params[:limit] || ''
            if limit_str != ''
              limit = cast_as_integer(limit_str)
              query = "#{query} LIMIT #{limit}"
            end

            tx.xquery(query).to_a
          end

        livestream_models.map do |livestream_model|
          fill_livestream_response(tx, livestream_model)
        end
      end

      json(livestreams)
    end

    get '/api/livestream' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestreams = db_transaction do |tx|
        ls_rows = tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user_id)
        ls_tags = livestream_tags_preload(tx, ls_rows)
        ls_rows.map do |livestream_model|
          fill_livestream_response(tx, livestream_model, all_tags: ls_tags)
        end
      end

      json(livestreams)
    end

    get '/api/user/:username/livestream' do
      verify_user_session!
      username = params[:username]

      livestreams = db_transaction do |tx|
        user = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user
          raise HttpError.new(404, 'user not found')
        end

        ls_rows = tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user.fetch(:id))
        ls_tags = livestream_tags_preload(tx, ls_rows)
        ls_rows.map do |livestream_model|
          fill_livestream_response(tx, livestream_model, all_tags: ls_tags)
        end
      end

      json(livestreams)
    end

    # ユーザ視聴開始 (viewer)
    post '/api/livestream/:livestream_id/enter' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      db_transaction do |tx|
        created_at = Time.now.to_i
        tx.xquery('INSERT INTO livestream_viewers_history (user_id, livestream_id, created_at) VALUES(?, ?, ?)', user_id, livestream_id, created_at)
      end

      ''
    end

    # ユーザ視聴終了 (viewer)
    delete '/api/livestream/:livestream_id/exit' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      db_transaction do |tx|
        tx.xquery('DELETE FROM livestream_viewers_history WHERE user_id = ? AND livestream_id = ?', user_id, livestream_id)
      end

      ''
    end

    # get livestream
    get '/api/livestream/:livestream_id' do
      verify_user_session!

      livestream_id = cast_as_integer(params[:livestream_id])

      livestream = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404)
        end

        fill_livestream_response(tx, livestream_model)
      end

      json(livestream)
    end

    # (配信者向け)ライブコメントの報告一覧取得API
    get '/api/livestream/:livestream_id/report' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      reports = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        if livestream_model.fetch(:user_id) != user_id
          raise HttpError.new(403, "can't get other streamer's livecomment reports")
        end

        rows = tx.xquery('SELECT * FROM livecomment_reports WHERE livestream_id = ?', livestream_id).to_a
        livecomment_models = rows.empty? ? {}  : (
          tx.xquery('SELECT * FROM livecomments WHERE id = (?)', rows.map {_1.fetch(:livecomment_id) })
          .map { [_1.fetch(:id), _1] }
          .to_h
        )
        rows.map do |report_model|
          livecomment_model  =livecomment_models[report_model.fetch(:livecomment_id)]
          fill_livecomment_report_response(tx, report_model, livestream_model:, livecomment_model:)
        end
      end

      json(reports)
    end

    # get polling livecomment timeline
    get '/api/livestream/:livestream_id/livecomment' do
      verify_user_session!
      livestream_id = cast_as_integer(params[:livestream_id])

      livestream_model = db_conn.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
      livestream = fill_livestream_response(db_conn, livestream_model)

      livecomments = db_transaction do |tx|
        query = <<~SQL
        SELECT
          livecomments.id AS l_id,
          livecomments.livestream_id AS l_livestream_id,
          livecomments.comment AS l_comment,
          livecomments.tip AS l_tip,
          livecomments.created_at AS l_created_at,
          users.*
        FROM livecomments
        INNER JOIN users ON livecomments.user_id = users.id
        WHERE livestream_id = ?
        SQL

        limit_str = params[:limit] || ''
        if limit_str != ''
          limit = cast_as_integer(limit_str)
          query = "#{query} LIMIT #{limit}"
        end

        tx.xquery(query, livestream_id).map do |livecomment_model|
          # fill_livecomment_response
          {
            id: livecomment_model.fetch(:l_id),
            comment: livecomment_model.fetch(:l_comment),
            tip: livecomment_model.fetch(:l_tip),
            created_at: livecomment_model.fetch(:l_created_at),
            user: fill_user_response(tx, livecomment_model),
            livestream:,
          }
        end
      end

      json(livecomments)
    end

    get '/api/livestream/:livestream_id/ngwords' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      ng_words = db_transaction do |tx|
        tx.xquery('SELECT * FROM ng_words WHERE user_id = ? AND livestream_id = ? ORDER BY created_at DESC', user_id, livestream_id).to_a
      end

      json(ng_words)
    end

    PostLivecommentRequest = Data.define(
      :comment,
      :tip,
    )

    # ライブコメント投稿
    post '/api/livestream/:livestream_id/livecomment' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      req = decode_request_body(PostLivecommentRequest)

      livecomment = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404, 'livestream not found')
        end

        # スパム判定
        tx.xquery(
          'SELECT id, user_id, livestream_id, word FROM ng_words WHERE user_id = ? AND livestream_id = ?',
          livestream_model.fetch(:user_id), livestream_model.fetch(:id)
        ).each do |ng_word|
          hit_spam = req.comment.include?(ng_word.fetch(:word))
          logger.info("[hit_spam=#{hit_spam}] comment = #{req.comment}")

          if hit_spam
            raise HttpError.new(400, 'このコメントがスパム判定されました')
          end
        end

        now = Time.now.to_i
        tx.xquery('INSERT INTO livecomments (user_id, livestream_id, comment, tip, created_at) VALUES (?, ?, ?, ?, ?)', user_id, livestream_id, req.comment, req.tip, now)
        livecomment_id = tx.last_id

        # tips 数を加算
        tx.xquery('UPDATE users SET total_tips = total_tips + ?, score = score + ? WHERE id = ?', req.tip, req.tip, livestream_model.fetch(:user_id))
        tx.xquery('UPDATE livestreams SET total_tips = total_tips + ?, score = score + ? WHERE id = ?', req.tip, req.tip, livestream_model.fetch(:id))

        fill_livecomment_response(tx, {
          id: livecomment_id,
          user_id:,
          livestream_id:,
          comment: req.comment,
          tip: req.tip,
          created_at: now,
        }, livestream_model:)
      end

      status 201
      json(livecomment)
    end

    # ライブコメント報告
    post '/api/livestream/:livestream_id/livecomment/:livecomment_id/report' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])
      livecomment_id = cast_as_integer(params[:livecomment_id])

      report = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404, 'livestream not found')
        end

        livecomment_model = tx.xquery('SELECT * FROM livecomments WHERE id = ?', livecomment_id).first
        unless livecomment_model
          raise HttpError.new(404, 'livecomment not found')
        end

        now = Time.now.to_i
        tx.xquery('INSERT INTO livecomment_reports(user_id, livestream_id, livecomment_id, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, livecomment_id, now)
        report_id = tx.last_id

        fill_livecomment_report_response(tx, {
          id: report_id,
          user_id:,
          livestream_id:,
          livecomment_id:,
          created_at: now,
        }, livestream_model:, livecomment_model:)
      end

      status 201
      json(report)
    end

    ModerateRequest = Data.define(:ng_word)

    # 配信者によるモデレーション (NGワード登録)
    post '/api/livestream/:livestream_id/moderate' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      req = decode_request_body(ModerateRequest)

      word_id = db_transaction do |tx|
        # 配信者自身の配信に対するmoderateなのかを検証
        owned_livestreams = tx.xquery('SELECT * FROM livestreams WHERE id = ? AND user_id = ?', livestream_id, user_id).to_a
        if owned_livestreams.empty?
          raise HttpError.new(400, "A streamer can't moderate livestreams that other streamers own")
        end

        tx.xquery('INSERT INTO ng_words(user_id, livestream_id, word, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, req.ng_word, Time.now.to_i)
        word_id = tx.last_id

        # 過去の NG ワードはスキャン不要
        livecomments = tx.xquery('SELECT * FROM livecomments WHERE livestream_id = ? AND comment LIKE ?', livestream_id, "%#{req.ng_word}%").to_a

        unless livecomments.empty?
          tx.xquery("DELETE FROM livecomments WHERE id IN (?)", [livecomments.map {|lc| lc.fetch(:id) }])
          total_tips = livecomments.map {|lc| lc.fetch(:tip) }.inject(:+)
          tx.xquery('UPDATE users SET total_tips = total_tips - ?, score = score - ? WHERE id = ?', total_tips, total_tips, user_id)
          tx.xquery('UPDATE livestreams SET total_tips = total_tips - ?, score = score - ? WHERE id = ?', total_tips, total_tips, livestream_id)
        end

        # # ライブコメント一覧取得
        # tx.xquery('SELECT * FROM livecomments').each do |livecomment|
        #   query = <<~SQL
        #     DELETE FROM livecomments
        #     WHERE
        #     id = ? AND
        #     livestream_id = ? AND
        #     (SELECT COUNT(*)
        #     FROM
        #     (SELECT ? AS text) AS texts
        #     INNER JOIN
        #     (SELECT CONCAT('%', ?, '%')	AS pattern) AS patterns
        #     ON texts.text LIKE patterns.pattern) >= 1
        #   SQL
        #   tx.xquery(query, livecomment.fetch(:id), livestream_id, livecomment.fetch(:comment), ng_word.fetch(:word))
        # end

        word_id
      end

      status 201
      json(word_id:)
    end

    get '/api/livestream/:livestream_id/reaction' do
      verify_user_session!

      livestream_id = cast_as_integer(params[:livestream_id])

      reactions = db_transaction do |tx|
        query = 'SELECT * FROM reactions WHERE livestream_id = ? ORDER BY created_at DESC'
        limit_str = params[:limit] || ''
        if limit_str != ''
          limit = cast_as_integer(limit_str)
          query = "#{query} LIMIT #{limit}"
        end

        tx.xquery(query, livestream_id).map do |reaction_model|
          fill_reaction_response(tx, reaction_model)
        end
      end

      json(reactions)
    end

    PostReactionRequest = Data.define(:emoji_name)

    post '/api/livestream/:livestream_id/reaction' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = Integer(params[:livestream_id], 10)

      req = decode_request_body(PostReactionRequest)

      reaction = db_transaction do |tx|
        # リアクション数をインクリメント
        livestream = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        tx.xquery('UPDATE users SET total_reactions = total_reactions + 1, score = score + 1 WHERE id = ?', livestream.fetch(:user_id))
        tx.xquery('UPDATE livestreams SET total_reactions = total_reactions + 1, score = score + 1 WHERE id = ?', livestream_id)

        created_at = Time.now.to_i
        tx.xquery('INSERT INTO reactions (user_id, livestream_id, emoji_name, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, req.emoji_name, created_at)
        reaction_id = tx.last_id

        fill_reaction_response(tx, {
          id: reaction_id,
          user_id:,
          livestream_id:,
          emoji_name: req.emoji_name,
          created_at:,
        })
      end

      status 201
      json(reaction)
    end

    BCRYPT_DEFAULT_COST = 4
    FALLBACK_IMAGE = '../img/NoImage.jpg'

    # これもう nginx でなんとかしてください
    # 同等 path っぽいとこに置いてあります
    get '/api/user/:username/icon' do
      username = params[:username]
      これはうまいことやる
      user = tx.xquery('SELECT * FROM users WHERE name = ? LIMIT 1', username).first
      unless user
        raise HttpError.new(404, 'not found user that has the given username')
      end
      send_file FALLBACK_IMAGE
    end

    PostIconRequest = Data.define(:image)

    post '/api/icon' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      user = db_conn.xquery('SELECT * FROM users WHERE id = ?', user_id).first
      icon_path = File.join(ICON_BASE_DIR, user.fetch(:name))

      req = decode_request_body(PostIconRequest)
      image = Base64.decode64(req.image)
      File.binwrite(icon_path, image)

      db_conn.xquery('UPDATE users SET icon_hash = ? WHERE id = ?', Digest::SHA256.hexdigest(image), user_id)

      # req = decode_request_body(PostIconRequest)
      # image = Base64.decode64(req.image)

      # icon_id = db_transaction do |tx|
      #   tx.xquery('DELETE FROM icons WHERE user_id = ?', user_id)
      #   tx.xquery('INSERT INTO icons (user_id, image) VALUES (?, ?)', user_id, image)
      #   tx.last_id
      # end
      icon_id = user[:id]

      status 201
      json(
        id: icon_id,
      )
    end

    get '/api/user/me' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      user = db_transaction do |tx|
        user_model = tx.xquery('SELECT * FROM users WHERE id = ?', user_id).first
        unless user_model
          raise HttpError.new(404)
        end
        fill_user_response(tx, user_model)
      end

      json(user)
    end

    PostUserRequest = Data.define(
      :name,
      :display_name,
      :description,
      # password is non-hashed password.
      :password,
      :theme,
    )

    # ユーザ登録API
    post '/api/register' do
      req = decode_request_body(PostUserRequest)
      if req.name == 'pipe'
        raise HttpError.new(400, "the username 'pipe' is reserved")
      end

      hashed_password = BCrypt::Password.create(req.password, cost: BCRYPT_DEFAULT_COST)

      user = db_transaction do |tx|
        tx.xquery('INSERT INTO users (name, display_name, description, password, dark_mode) VALUES(?, ?, ?, ?, ?)', req.name, req.display_name, req.description, hashed_password, req.theme.fetch(:dark_mode))
        user_id = tx.last_id

        #out, status = Open3.capture2e('pdnsutil', 'add-record', 'u.isucon.dev', req.name, 'A', '0', POWERDNS_SUBDOMAIN_ADDRESS)
        #unless status.success?
        #  raise HttpError.new(500, "pdnsutil failed with out=#{out}")
        #end
        File.open(ZONE_FILE, 'a') do |io|
          io.flock(File::LOCK_EX)
          io.seek(0, IO::SEEK_END)
          io.puts "#{req.name} IN A #{POWERDNS_SUBDOMAIN_ADDRESS}"
        end
        spawn('nsd-control', 'reload', 'u.isucon.dev')

        # アイコン登録
        FileUtils.cp(FALLBACK_IMAGE, File.join(ICON_BASE_DIR, req.name))

        fill_user_response(tx, {
          id: user_id,
          name: req.name,
          display_name: req.display_name,
          description: req.description,
          icon_hash: "d9f8294e9d895f81ce62e73dc7d5dff862a4fa40bd4e0fecf53f7526a8edcac0",
          dark_mode: req.theme.fetch(:dark_mode),
        })
      end

      status 201
      json(user)
    end

    LoginRequest = Data.define(
      :username,
      # password is non-hashed password.
      :password,
    )

    # ユーザログインAPI
    post '/api/login' do
      req = decode_request_body(LoginRequest)

      user_model = db_transaction do |tx|
        # usernameはUNIQUEなので、whereで一意に特定できる
        tx.xquery('SELECT * FROM users WHERE name = ?', req.username).first.tap do |user_model|
          unless user_model
            raise HttpError.new(401, 'invalid username or password')
          end
        end
      end

      unless BCrypt::Password.new(user_model.fetch(:password)).is_password?(req.password)
        raise HttpError.new(401, 'invalid username or password')
      end

      session_end_at = Time.now + 10*60*60
      session_id = SecureRandom.uuid
      session[DEFAULT_SESSION_ID_KEY] = {
        DEFAULT_SESSION_ID_KEY => session_id,
        DEFAULT_USER_ID_KEY => user_model.fetch(:id),
        DEFAULT_USERNAME_KEY => user_model.fetch(:name),
        DEFAULT_SESSION_EXPIRES_KEY => session_end_at.to_i,
      }

      ''
    end

    # ユーザ詳細API
    get '/api/user/:username' do
      verify_user_session!

      username = params[:username]

      user = db_transaction do |tx|
        user_model = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user_model
          raise HttpError.new(404)
        end

        fill_user_response(tx, user_model)
      end

      json(user)
    end

    UserRankingEntry = Data.define(:username, :score)

    get '/api/user/:username/statistics' do
      verify_user_session!

      username = params[:username]

      # ユーザごとに、紐づく配信について、累計リアクション数、累計ライブコメント数、累計売上金額を算出
      # また、現在の合計視聴者数もだす

      stats = db_transaction do |tx|
        user = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user
          raise HttpError.new(400)
        end

        # ランク算出
        users = tx.xquery('SELECT name FROM users ORDER BY score ASC, name ASC').to_a
        ridx = users.rindex { |entry| entry.fetch(:name) == username }
        rank = users.size - ridx

        # リアクション数
        total_reactions = user.fetch(:total_reactions)
        # total_reactions = tx.xquery(<<~SQL, username, as: :array).first[0]
        #   SELECT COUNT(*) FROM users u
        #   INNER JOIN livestreams l ON l.user_id = u.id
        #   INNER JOIN reactions r ON r.livestream_id = l.id
        #   WHERE u.name = ?
        # SQL

        total_tip = user.fetch(:total_tips)

        # ライブコメント数、チップ合計
        total_livecomments = 0
        livestreams = tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user.fetch(:id))
        livestreams.each do |livestream|
          tx.xquery('SELECT * FROM livecomments WHERE livestream_id = ?', livestream.fetch(:id)).each do |livecomment|
            total_livecomments += 1
          end
        end

        # 合計視聴者数
        viewers_count = 0
        livestreams.each do |livestream|
          cnt = tx.xquery('SELECT COUNT(*) FROM livestream_viewers_history WHERE livestream_id = ?', livestream.fetch(:id), as: :array).first[0]
          viewers_count += cnt
        end

        # お気に入り絵文字
        favorite_emoji = tx.xquery(<<~SQL, username).first&.fetch(:emoji_name)
          SELECT r.emoji_name
          FROM users u
          INNER JOIN livestreams l ON l.user_id = u.id
          INNER JOIN reactions r ON r.livestream_id = l.id
          WHERE u.name = ?
          GROUP BY emoji_name
          ORDER BY COUNT(*) DESC, emoji_name DESC
          LIMIT 1
        SQL

        {
          rank:,
          viewers_count:,
          total_reactions:,
          total_livecomments:,
          total_tip:,
          favorite_emoji:,
        }
      end

      json(stats)
    end

    LivestreamRankingEntry = Data.define(:livestream_id, :score)

    # ライブ配信統計情報
    get '/api/livestream/:livestream_id/statistics' do
      verify_user_session!
      livestream_id = cast_as_integer(params[:livestream_id])

      stats = db_transaction do |tx|
        unless tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
          raise HttpError.new(400)
        end

        # ランク算出
        ranking = tx.xquery('SELECT id FROM livestreams ORDER BY score ASC, id ASC').to_a
        ridx = ranking.rindex { |entry| entry.fetch(:id) == livestream_id }
        rank = ranking.size - ridx

        # 視聴者数算出
        viewers_count = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN livestream_viewers_history h ON h.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

        # 最大チップ額
        max_tip = tx.xquery('SELECT IFNULL(MAX(tip), 0) FROM livestreams l INNER JOIN livecomments l2 ON l2.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

        # リアクション数
        total_reactions = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN reactions r ON r.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

        # スパム報告数
        total_reports = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN livecomment_reports r ON r.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

        {
          rank:,
          viewers_count:,
          max_tip:,
          total_reactions:,
          total_reports:,
        }
      end

      json(stats)
    end

    get '/api/payment' do
      total_tip = db_transaction do |tx|
        tx.xquery('SELECT IFNULL(SUM(tip), 0) FROM livecomments', as: :array).first[0]
      end

      json(total_tip:)
    end

    get '/*' do
      send_file File.join(settings.public_folder, 'index.html')
    end
  end
end
