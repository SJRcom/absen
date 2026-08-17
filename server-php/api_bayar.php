<?php
/**
 * api_bayar.php — versi diperbaiki
 *
 * Endpoint untuk absensi NFC dari aplikasi Absensi SJR.
 * Menerima POST JSON:  {"id_member": "SJR24-00013"}
 * 1) Mencari tiket (invoice) terbuka milik member tsb.
 * 2) Menutup invoice di inv_mabol.
 * 3) Menandai bayar='1' di tim_detail (sesuai kebutuhan — bisa dimatikan).
 * Selalu membalas JSON yang akurat (tidak pernah 500 untuk kondisi normal).
 *
 * ===== KOLOM DATABASE YANG DIPAKAI =====
 * Verifikasi di server utama dengan perintah:
 *     DESCRIBE inv_mabol;   DESCRIBE tim_detail;   DESCRIBE jadwalmabol;
 *   inv_mabol   : id_member, kode_warlist, kode_mabol, jml_absen, status_inv, nomor
 *   tim_detail  : kode_warlist, id_member, bayar, absen, status
 *   jadwalmabol : (tidak dipakai lagi — JOIN sengaja dihapus, lihat bawah)
 *
 * Catatan: file koneksinya.php (kredensial DB) TIDAK ikut di repo — harus
 * sudah ada di folder yang sama di server utama.
 */

// ===== CORS lengkap: Origin, Headers, Methods + preflight OPTIONS =====
header("Access-Control-Allow-Origin: *");
header("Access-Control-Allow-Headers: Content-Type");
header("Access-Control-Allow-Methods: GET, POST, OPTIONS");
header("Content-Type: application/json; charset=utf-8");

$method = $_SERVER['REQUEST_METHOD'];

// Preflight CORS: browser mengirim OPTIONS sebelum POST — jawab 200 tanpa proses apa pun.
if ($method === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// Hanya POST yang didukung (GET lama memakai tabel placeholder 'nama_tabel' dan tidak pernah jalan).
if ($method !== 'POST') {
    http_response_code(405);
    echo json_encode(["status" => "error", "message" => "Metode $method tidak didukung. Gunakan POST."]);
    exit;
}

include 'koneksinya.php';

// ===== Baca body JSON dengan aman =====
$input = json_decode(file_get_contents('php://input'), true);
$id_member = isset($input['id_member']) ? trim((string) $input['id_member']) : '';

if ($id_member === '') {
    http_response_code(400);
    echo json_encode(["status" => "error", "message" => "Submit gagal! id_member tidak boleh kosong."]);
    exit;
}

$id_member_safe = mysqli_real_escape_string($conn, $id_member);

// ===== 1) Cari tiket terbuka milik member (dengan proteksi SQL injection) =====
// JOIN ke jadwalmabol sengaja DIHAPUS: tidak ada kolom dari tabel itu yang
// dipakai, dan INNER JOIN bisa membuat invoice terbuka "hilang" dari hasil
// (kalau baris jadwalnya tidak ada) → member ditolak padahal tiketnya ada.
$sql = "SELECT a.kode_warlist, a.jml_absen
        FROM inv_mabol a
        WHERE a.id_member = '$id_member_safe' AND a.status_inv = 'open'
        ORDER BY a.nomor DESC
        LIMIT 1";
$result = mysqli_query($conn, $sql);
if (!$result) {
    http_response_code(500);
    echo json_encode(["status" => "error", "message" => "Terjadi kesalahan database saat mencari tiket."]);
    exit;
}
$inv = mysqli_fetch_assoc($result);

if (!$inv) {
    // Kondisi normal (bukan error server): member tidak punya tiket terbuka.
    echo json_encode(["status" => "error", "message" => "GAGAL: tidak ada tiket terbuka untuk member $id_member."]);
    exit;
}

$kode_warlist = $inv['kode_warlist'];
$absen = (int) $inv['jml_absen'];
$kode_warlist_safe = mysqli_real_escape_string($conn, $kode_warlist);

// ===== 2 & 3) Tutup invoice + tandai bayar, dibungkus SATU transaksi =====
// Kalau salah satu update gagal, keduanya di-rollback — tidak ada kondisi
// "invoice tertutup tapi ceklist tidak terisi" (atau sebaliknya).
mysqli_begin_transaction($conn);

// 2) Tutup invoice — di-scope per member + status masih 'open', supaya tap
//    ganda/bersamaan tidak menutup invoice member lain di warlist yang sama.
$sql = "UPDATE inv_mabol SET status_inv = 'close'
        WHERE kode_warlist = '$kode_warlist_safe'
          AND id_member = '$id_member_safe'
          AND status_inv = 'open'";
$invoice_ok = mysqli_query($conn, $sql);

// 3) Tandai bayar + absen di tim_detail — HANYA baris milik member yang tap.
//    Perhatian: pastikan nama kolom member di tim_detail benar (`id_member`).
//    Kalau di server utama namanya beda (mis. no_member), sesuaikan di sini.
$sql = "UPDATE tim_detail SET bayar = '1', absen = '$absen'
        WHERE kode_warlist = '$kode_warlist_safe'
          AND id_member = '$id_member_safe'
          AND status = 'listed'";
$detail_ok = mysqli_query($conn, $sql);

// Cek hasil KEDUA update — kalau salah satu gagal (mis. kolom tidak ada),
// rollback dan beri tahu, jangan diam-diam melaporkan sukses.
if ($invoice_ok === false || $detail_ok === false) {
    mysqli_rollback($conn);
    http_response_code(500);
    echo json_encode([
        "status" => "error",
        "message" => "Gagal menyimpan data. Periksa nama kolom tabel (lihat komentar atas).",
    ]);
    exit;
}

$detail_rows = mysqli_affected_rows($conn);
mysqli_commit($conn);

// affected_rows bernilai 0 kalau barisnya sudah ter-update sebelumnya (tap
// ganda) — itu kondisi normal, bukan error.
echo json_encode([
    "status" => "success",
    "message" => "Absen berhasil — data tersimpan.",
    "id_member" => $id_member,
    "kode_warlist" => $kode_warlist,
    "jml_absen" => $absen,
    "tim_detail_rows" => $detail_rows,
]);

mysqli_close($conn);
