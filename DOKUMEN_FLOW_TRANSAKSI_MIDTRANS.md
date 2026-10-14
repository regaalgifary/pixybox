# DOKUMEN FLOW TRANSAKSI PEMBAYARAN MIDTRANS
**Layanan Mesin Kiosk Self-Service Photobox — PIXYBOX**

---

## 1. INFORMASI MERCHANT & APLIKASI

| Parameter | Keterangan |
| :--- | :--- |
| **Nama Merchant** | Pixybox |
| **Merchant ID Midtrans** | M681064478 |
| **Jenis Usaha** | Jasa Photobox Mandiri / Self-Service Photo Booth Kiosk |
| **Platform Aplikasi** | Desktop Application (Windows Kiosk) |
| **Integrasi Pembayaran** | Midtrans Core API (QRIS Dinamis - GoPay / ShopeePay / All E-Wallet & Mobile Banking) |


---

## 2. DESKRIPSI SINGKAT LAYANAN
**Pixybox** adalah layanan mesin photobox otomatis (self-service photobooth) yang ditempatkan pada lokasi fisik (mall, kafe, event). Pelanggan berinteraksi langsung melalui monitor layar sentuh (*touchscreen*) kiosk. Alur transaksi dimulai dari pemilihan jumlah cetak foto, pembayaran otomatis secara cashless menggunakan **QRIS Midtrans**, hingga pelaksanaan sesi foto dan pencetakan hasil foto secara langsung.

---

## 3. STEP-BY-STEP FLOW TRANSAKSI (PEMILIHAN PRODUK S.D. CHECKOUT)

### **Langkah 1: Layar Utama / Sambutan (Welcome Screen)**
* **Keterangan:**  
  Pelanggan mendatangi booth Pixybox. Layar menampilkan sambutan dan tombol sentuh untuk memulai sesi. Pelanggan menekan tombol **"Sentuh Layar untuk Mulai"** / **"Mulai Sesi"**.
* **Tindakan Sistem:**  
  Aplikasi membuka sesi transaksi baru dan mengarahkan pengguna ke halaman pemilihan paket layanan.

> **[TEMPATKAN SCREENSHOT 1 DI SINI]**  
> *(Ambil screenshot tampilan layar awal / Welcome Screen Pixybox)*

---

### **Langkah 2: Pemilihan Produk & Jumlah Cetak (Product Selection)**
* **Keterangan:**  
  Pelanggan disajikan pilihan paket cetak foto, misalnya:
  * Paket 1 Lembar Cetak: Rp 25.000
  * Paket 2 Lembar Cetak: Rp 35.000
* **Tindakan Pengguna:**  
  Pelanggan memilih jumlah cetak yang diinginkan.
* **Tindakan Sistem:**  
  Aplikasi menghitung total biaya transaksi sesuai paket yang dipilih dan menampilkan rincian nominal pembayaran.

> **[TEMPATKAN SCREENSHOT 2 DI SINI]**  
> *(Ambil screenshot tampilan pemilihan jumlah cetak foto dan nominal harga pada layar Pixybox)*

---

### **Langkah 3: Checkout & Pembuatan Kode QRIS Dinamis Midtrans**
* **Keterangan:**  
  Setelah menentukan paket, sistem secara otomatis (atau pelanggan menekan tombol **"Lanjut Pembayaran"**) memulai proses checkout.
* **Tindakan Sistem (Integrasi Midtrans):**  
  Aplikasi Pixybox mengirimkan request API ke endpoint Midtrans:
  * **Endpoint:** `POST https://api.midtrans.com/v2/charge`
  * **Parameter:** `payment_type: "qris"`, `gross_amount: [Nominal]`, `order_id: "PB-[ID]-[Timestamp]"`
  * Midtrans mengembalikan URL gambar QRIS dinamis dan batas waktu pembayaran (expiry time).

> **[TEMPATKAN SCREENSHOT 3 DI SINI]**  
> *(Ambil screenshot saat aplikasi memuat proses pembayaran / loading QRIS)*

---

### **Langkah 4: Tampilan Kode QRIS Midtrans & Proses Pembayaran Pelanggan**
* **Keterangan:**  
  Layar Kiosk menampilkan QR Code QRIS resmi Midtrans beserta instruksi pembayaran dan rincian total nominal yang harus dibayar.
* **Tindakan Pengguna:**  
  Pelanggan membuka aplikasi Mobile Banking (BCA Mobile, Livin by Mandiri, BRImo, CIMB, dll.) atau E-Wallet (GoPay, OVO, ShopeePay, DANA, LinkAja) lalu melakukan pemindaian (*scan*) pada kode QRIS yang tampil di layar kiosk dan menekan bayar.
* **Tindakan Sistem:**  
  Aplikasi menjalankan polling pengecekan status pembayaran secara real-time ke Midtrans API (`GET /v2/{order_id}/status`).

> **[TEMPATKAN SCREENSHOT 4 DI SINI]**  
> *(Ambil screenshot layar Pixybox yang sedang menampilkan QRIS Midtrans, nominal harga, dan instruksi bayar)*

---

### **Langkah 5: Konfirmasi Pembayaran Berhasil (Payment Settlement)**
* **Keterangan:**  
  Setelah pelanggan menyelesaikan pembayaran pada smartphone mereka, Midtrans mencatat status transaksi menjadi `settlement`.
* **Tindakan Sistem:**  
  Aplikasi Pixybox menerima konfirmasi status lunas, mematikan timer QRIS, menampilkan pesan **"Pembayaran Berhasil"**, dan secara otomatis mengalihkan layar ke tahap sesi pemotretan foto (*Shooting Stage*).

> **[TEMPATKAN SCREENSHOT 5 DI SINI]**  
> *(Ambil screenshot konfirmasi pembayaran berhasil atau transisi masuk ke kamera)*

---

### **Langkah 6: Sesi Pemotretan Foto & Pemilihan Template (Fulfillment Layanan)**
* **Keterangan:**  
  Pelanggan melakukan sesi foto di depan kamera dengan hitung mundur otomatis (*countdown*). Setelah sesi foto selesai, pelanggan memilih template/desain bingkai foto yang disukai.
* **Tindakan Sistem:**  
  Sistem menggabungkan hasil foto dengan template yang dipilih.

> **[TEMPATKAN SCREENSHOT 6 DI SINI]**  
> *(Ambil screenshot layar pengambilan foto kamera / pemilihan template bingkai)*

---

### **Langkah 7: Pencetakan Foto Fisik & Selesai**
* **Keterangan:**  
  Mesin printer Pixybox secara otomatis mencetak lembaran foto fisik sesuai jumlah pesanan yang telah dibayar pada awal sesi. Sesi selesai dan layar kembali siap untuk pelanggan berikutnya.

> **[TEMPATKAN SCREENSHOT 7 DI SINI]**  
> *(Ambil screenshot proses cetak / tampilan terima kasih pada layar)*

---

## 4. KEBIJAKAN PENGEMBALIAN DANA (REFUND) & BANTUAN PELANGGAN
* Apabila terjadi kendala teknis (seperti kertas printer habis atau mati listrik saat pembayaran telah terpotong), pelanggan dapat menghubungi Customer Support yang tertera pada badan mesin booth:
  * **WhatsApp Support:** 0812-xxxx-xxxx
  * **Email:** support@pixybox.com
* Pengembalian dana (*refund*) atau pemberian sesi ulang diproses dalam waktu maksimal $1 \times 24$ jam setelah verifikasi bukti pembayaran.

---
*Dokumen ini disusun untuk keperluan verifikasi aktivasi Payment Method QRIS Midtrans Merchant ID: M681064478.*
