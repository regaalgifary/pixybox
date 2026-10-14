-- Script SQL untuk Inisialisasi Database Pixybox
-- Impor file ini ke phpMyAdmin pada database bernama 'pixybox'

CREATE TABLE IF NOT EXISTS `users` (
  `id_user` INT AUTO_INCREMENT PRIMARY KEY,
  `username` VARCHAR(50) NOT NULL UNIQUE,
  `password` VARCHAR(255) NOT NULL,
  `role` VARCHAR(20) NOT NULL DEFAULT 'booth',
  `alamat_photobox` TEXT,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `prices` (
  `id_price` INT AUTO_INCREMENT PRIMARY KEY,
  `id_user` INT NOT NULL,
  `print_count` INT NOT NULL, -- Jumlah cetak (misal 1 untuk 1x print, 2 untuk 2x print)
  `price` DECIMAL(10, 2) NOT NULL, -- Harga dalam Rupiah
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (`id_user`) REFERENCES `users`(`id_user`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Insert Mock Data Akun Photobox
INSERT INTO `users` (`id_user`, `username`, `password`, `role`, `alamat_photobox`) VALUES
(1, 'photobox_01', 'password123', 'booth', 'Mall Kelapa Gading, Jakarta'),
(2, 'photobox_02', 'password123', 'booth', 'Tunjungan Plaza, Surabaya'),
(3, 'admin_pixy', 'admin123', 'admin', 'Head Office Jakarta');

-- Insert Mock Data Daftar Harga
-- Untuk photobox_01 (Mall Kelapa Gading)
INSERT INTO `prices` (`id_user`, `print_count`, `price`) VALUES
(1, 1, 25000.00), -- 1x Print = Rp 25.000
(1, 2, 35000.00); -- 2x Print = Rp 35.000

-- Untuk photobox_02 (Tunjungan Plaza)
INSERT INTO `prices` (`id_user`, `print_count`, `price`) VALUES
(2, 1, 30000.00), -- 1x Print = Rp 30.000
(2, 2, 45000.00); -- 2x Print = Rp 45.000

CREATE TABLE IF NOT EXISTS `templates` (
  `id_template` INT AUTO_INCREMENT PRIMARY KEY,
  `id_user` INT NOT NULL,
  `name` VARCHAR(100) NOT NULL,
  `image_data` LONGBLOB NOT NULL, -- The transparent PNG template bytes
  `slot1_x` DOUBLE NOT NULL DEFAULT 0.1,
  `slot1_y` DOUBLE NOT NULL DEFAULT 0.1,
  `slot1_w` DOUBLE NOT NULL DEFAULT 0.8,
  `slot1_h` DOUBLE NOT NULL DEFAULT 0.25,
  `slot2_x` DOUBLE NOT NULL DEFAULT 0.1,
  `slot2_y` DOUBLE NOT NULL DEFAULT 0.4,
  `slot2_w` DOUBLE NOT NULL DEFAULT 0.8,
  `slot2_h` DOUBLE NOT NULL DEFAULT 0.25,
  `slot3_x` DOUBLE NOT NULL DEFAULT 0.1,
  `slot3_y` DOUBLE NOT NULL DEFAULT 0.7,
  `slot3_w` DOUBLE NOT NULL DEFAULT 0.8,
  `slot3_h` DOUBLE NOT NULL DEFAULT 0.25,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (`id_user`) REFERENCES `users`(`id_user`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `template_assignments` (
  `id_assignment` INT AUTO_INCREMENT PRIMARY KEY,
  `id_template` INT NOT NULL,
  `id_user` INT NOT NULL,
  FOREIGN KEY (`id_template`) REFERENCES `templates`(`id_template`) ON DELETE CASCADE,
  FOREIGN KEY (`id_user`) REFERENCES `users`(`id_user`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `session_history` (
  `id_session` INT AUTO_INCREMENT PRIMARY KEY,
  `order_id` VARCHAR(100) NOT NULL UNIQUE,
  `id_user` INT NOT NULL COMMENT 'ID akun booth photobox',
  `id_template` INT NULL COMMENT 'ID template yang digunakan',
  `template_name` VARCHAR(100) NULL COMMENT 'Nama template snapshot jika template terhapus',
  `print_count` INT NOT NULL DEFAULT 1 COMMENT 'Jumlah lembar cetak',
  `total_price` DECIMAL(12, 2) NOT NULL DEFAULT 0.00 COMMENT 'Total nominal transaksi (Rp)',
  `payment_type` VARCHAR(50) NOT NULL DEFAULT 'qris' COMMENT 'Metode bayar',
  `payment_status` VARCHAR(50) NOT NULL DEFAULT 'pending' COMMENT 'Status Midtrans (pending, settlement, expire, cancel)',
  `session_status` VARCHAR(50) NOT NULL DEFAULT 'started' COMMENT 'Status alur sesi (started, paid, completed, cancelled)',
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX `idx_order_id` (`order_id`),
  INDEX `idx_user_date` (`id_user`, `created_at`),
  INDEX `idx_payment_status` (`payment_status`),
  FOREIGN KEY (`id_user`) REFERENCES `users`(`id_user`) ON DELETE CASCADE,
  FOREIGN KEY (`id_template`) REFERENCES `templates`(`id_template`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

