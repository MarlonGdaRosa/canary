-- Local AAC additions only. Never import the destructive upstream canaryaac.sql.
ALTER TABLE `accounts` ADD COLUMN IF NOT EXISTS `page_access` INT NOT NULL DEFAULT 0;
ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `main` INT NOT NULL DEFAULT 0;
ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `world` INT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS `canary_website` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `timezone` VARCHAR(150) NOT NULL,
  `title` VARCHAR(70) NOT NULL,
  `downloads` VARCHAR(250) NOT NULL,
  `discord` VARCHAR(250) NOT NULL,
  `player_voc` INT NOT NULL,
  `player_max` INT NOT NULL,
  `player_guild` INT NOT NULL,
  `donates` INT NOT NULL,
  `coin_price` DECIMAL(10,2) NOT NULL,
  `mercadopago` INT NOT NULL,
  `pagseguro` INT NOT NULL,
  `paypal` INT NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `canary_worlds` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `name` VARCHAR(80) NOT NULL,
  `creation` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `location` INT NOT NULL DEFAULT 0,
  `pvp_type` INT NOT NULL DEFAULT 0,
  `premium_type` INT NOT NULL DEFAULT 0,
  `transfer_type` INT NOT NULL DEFAULT 0,
  `battle_eye` INT NOT NULL DEFAULT 0,
  `world_type` INT NOT NULL DEFAULT 0,
  `ip` VARCHAR(18) NOT NULL,
  `port` INT NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `canary_samples` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `vocation` INT NOT NULL,
  `experience` INT NOT NULL,
  `level` INT NOT NULL,
  `health` INT NOT NULL,
  `healthmax` INT NOT NULL,
  `maglevel` INT NOT NULL,
  `mana` INT NOT NULL,
  `manamax` INT NOT NULL,
  `manaspent` INT NOT NULL,
  `soul` INT NOT NULL,
  `town_id` INT NOT NULL,
  `posx` INT NOT NULL,
  `posy` INT NOT NULL,
  `posz` INT NOT NULL,
  `cap` INT NOT NULL,
  `balance` INT NOT NULL,
  `lookbody` INT NOT NULL,
  `lookfeet` INT NOT NULL,
  `lookhead` INT NOT NULL,
  `looklegs` INT NOT NULL,
  `looktype` INT NOT NULL,
  `lookaddons` INT NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `canary_countdowns` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `date_start` INT NOT NULL,
  `date_end` INT NOT NULL,
  `themebox` VARCHAR(250) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `canary_polls` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `player_id` INT NOT NULL DEFAULT 0,
  `title` VARCHAR(250) NOT NULL,
  `description` VARCHAR(500) NOT NULL,
  `date_start` INT NOT NULL,
  `date_end` INT NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `canary_polls_questions` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `poll_id` INT NOT NULL,
  `question` VARCHAR(250) NOT NULL,
  `description` VARCHAR(500) NOT NULL,
  `votes` INT NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `canary_website`
(`id`, `timezone`, `title`, `downloads`, `discord`, `player_voc`, `player_max`, `player_guild`, `donates`, `coin_price`, `mercadopago`, `pagseguro`, `paypal`) VALUES
(1, 'America/Sao_Paulo', 'Canary Local', '', '', 1, 10, 100, 0, 0.00, 0, 0, 0)
ON DUPLICATE KEY UPDATE
`timezone`=VALUES(`timezone`), `title`=VALUES(`title`), `downloads`=VALUES(`downloads`), `discord`=VALUES(`discord`),
`player_voc`=VALUES(`player_voc`), `player_max`=VALUES(`player_max`), `player_guild`=VALUES(`player_guild`),
`donates`=VALUES(`donates`), `coin_price`=VALUES(`coin_price`), `mercadopago`=VALUES(`mercadopago`), `pagseguro`=VALUES(`pagseguro`), `paypal`=VALUES(`paypal`);

INSERT INTO `canary_worlds`
(`id`, `name`, `location`, `pvp_type`, `premium_type`, `transfer_type`, `battle_eye`, `world_type`, `ip`, `port`) VALUES
(1, 'Canary Local', 7, 0, 0, 0, 0, 0, '127.0.0.1', 7172)
ON DUPLICATE KEY UPDATE
`name`=VALUES(`name`), `location`=VALUES(`location`), `pvp_type`=VALUES(`pvp_type`), `premium_type`=VALUES(`premium_type`),
`transfer_type`=VALUES(`transfer_type`), `battle_eye`=VALUES(`battle_eye`), `world_type`=VALUES(`world_type`), `ip`=VALUES(`ip`), `port`=VALUES(`port`);

INSERT INTO `canary_samples`
(`id`, `vocation`, `experience`, `level`, `health`, `healthmax`, `maglevel`, `mana`, `manamax`, `manaspent`, `soul`, `town_id`, `posx`, `posy`, `posz`, `cap`, `balance`, `lookbody`, `lookfeet`, `lookhead`, `looklegs`, `looktype`, `lookaddons`) VALUES
(1, 1, 4200, 8, 185, 185, 0, 90, 90, 0, 0, 8, 32369, 32241, 7, 470, 0, 113, 115, 95, 39, 129, 0),
(2, 2, 4200, 8, 185, 185, 0, 90, 90, 0, 0, 8, 32369, 32241, 7, 470, 0, 113, 115, 95, 39, 129, 0),
(3, 3, 4200, 8, 185, 185, 0, 90, 90, 0, 0, 8, 32369, 32241, 7, 470, 0, 113, 115, 95, 39, 129, 0),
(4, 4, 4200, 8, 185, 185, 0, 90, 90, 0, 0, 8, 32369, 32241, 7, 470, 0, 113, 115, 95, 39, 129, 0),
(9, 9, 4200, 8, 185, 185, 0, 90, 90, 0, 0, 8, 32369, 32241, 7, 470, 0, 113, 115, 95, 39, 129, 0)
ON DUPLICATE KEY UPDATE
`vocation`=VALUES(`vocation`), `experience`=VALUES(`experience`), `level`=VALUES(`level`), `health`=VALUES(`health`), `healthmax`=VALUES(`healthmax`),
`maglevel`=VALUES(`maglevel`), `mana`=VALUES(`mana`), `manamax`=VALUES(`manamax`), `manaspent`=VALUES(`manaspent`), `soul`=VALUES(`soul`),
`town_id`=VALUES(`town_id`), `posx`=VALUES(`posx`), `posy`=VALUES(`posy`), `posz`=VALUES(`posz`), `cap`=VALUES(`cap`), `balance`=VALUES(`balance`),
`lookbody`=VALUES(`lookbody`), `lookfeet`=VALUES(`lookfeet`), `lookhead`=VALUES(`lookhead`), `looklegs`=VALUES(`looklegs`), `looktype`=VALUES(`looktype`), `lookaddons`=VALUES(`lookaddons`);
