USE `isupipe`;

-- ユーザ (配信者、視聴者) / WITH INSERT
CREATE TABLE `users` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `name` VARCHAR(255) NOT NULL,
  `display_name` VARCHAR(255) NOT NULL,
  `password` VARCHAR(255) NOT NULL,
  `description` TEXT NOT NULL,
  `icon_hash` VARCHAR(255) NOT NULL DEFAULT 'd9f8294e9d895f81ce62e73dc7d5dff862a4fa40bd4e0fecf53f7526a8edcac0',

  `total_tips` BIGINT NOT NULL DEFAULT 0,
  `total_reactions` BIGINT NOT NULL DEFAULT 0,
  `score` BIGINT NOT NULL DEFAULT 0,
  `dark_mode` BOOLEAN NOT NULL DEFAULT false,

  UNIQUE `uniq_user_name` (`name`)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table users add index idx1 (score, name);

-- プロフィール画像 / WITH INSERT / WITH DELETE
CREATE TABLE `icons` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `image` LONGBLOB NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table icons add index idx1 (user_id);

-- ユーザごとのカスタムテーマ / WITH INSERT
CREATE TABLE `themes` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `dark_mode` BOOLEAN NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table themes add index idx1 (user_id);

-- ライブ配信 / WITH INSERT
CREATE TABLE `livestreams` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `title` VARCHAR(255) NOT NULL,
  `description` text NOT NULL,
  `playlist_url` VARCHAR(255) NOT NULL,
  `thumbnail_url` VARCHAR(255) NOT NULL,

  `total_tips` BIGINT NOT NULL DEFAULT 0,
  `total_reactions` BIGINT NOT NULL DEFAULT 0,
  `score` BIGINT NOT NULL DEFAULT 0,

  `start_at` BIGINT NOT NULL,
  `end_at` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table livestreams add index idx1 (user_id);
alter table livestreams add index idx2 (score asc, id asc);

-- ライブ配信予約枠 / WITH UPDATE
CREATE TABLE `reservation_slots` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `slot` BIGINT NOT NULL,
  `start_at` BIGINT NOT NULL,
  `end_at` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table reservation_slots add index idx1 (start_at, end_at);

-- ライブストリームに付与される、サービスで定義されたタグ
CREATE TABLE `tags` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `name` VARCHAR(255) NOT NULL,
  UNIQUE `uniq_tag_name` (`name`)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

-- ライブ配信とタグの中間テーブル / WITH INSERT
CREATE TABLE `livestream_tags` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `livestream_id` BIGINT NOT NULL,
  `tag_id` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table livestream_tags add index idx1 (livestream_id);

-- ライブ配信視聴履歴 / WITH INSERT / WITH DELETE
CREATE TABLE `livestream_viewers_history` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `livestream_id` BIGINT NOT NULL,
  `created_at` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

-- ライブ配信に対するライブコメント / WITH INSERT / WITH DELETE
CREATE TABLE `livecomments` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `livestream_id` BIGINT NOT NULL,
  `comment` VARCHAR(255) NOT NULL,
  `tip` BIGINT NOT NULL DEFAULT 0,
  `created_at` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table livecomments add index idx1 (livestream_id, tip);
alter table livecomments add index idx2 (livestream_id, created_at desc);

-- ユーザからのライブコメントのスパム報告 / WITH INSERT
CREATE TABLE `livecomment_reports` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `livestream_id` BIGINT NOT NULL,
  `livecomment_id` BIGINT NOT NULL,
  `created_at` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

-- 配信者からのNGワード登録 / WITH INSERT
CREATE TABLE `ng_words` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `livestream_id` BIGINT NOT NULL,
  `word` VARCHAR(255) NOT NULL,
  `created_at` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE INDEX ng_words_word ON ng_words(`word`);

alter table ng_words add index idx1 (user_id, livestream_id);

-- ライブ配信に対するリアクション / WITH INSERT
CREATE TABLE `reactions` (
  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `livestream_id` BIGINT NOT NULL,
  -- :innocent:, :tada:, etc...
  `emoji_name` VARCHAR(255) NOT NULL,
  `created_at` BIGINT NOT NULL
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

alter table reactions add index idx1 (livestream_id);
alter table reactions add index idx2 (livestream_id, created_at desc);
