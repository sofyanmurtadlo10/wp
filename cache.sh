#!/usr/bin/env bash

#================================================================
# SKRIP PENGHAPUSAN TOTAL FASTCGI & REDIS CACHE
#================================================================
# PERINGATAN: Skrip ini akan menghapus semua konfigurasi cache
# dan software terkait Redis secara permanen dari server Anda.
# Lanjutkan hanya jika Anda benar-benar yakin.
#================================================================

if [[ $EUID -ne 0 ]]; then
    echo "❌ Kesalahan: Skrip ini harus dijalankan sebagai root. Coba 'sudo bash $0'"
    exit 1
fi

#--- Variabel Warna ---
C_RESET='\e[0m'
C_RED='\e[1;31m'
C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m'
C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

#--- Fungsi Bantuan ---
log() {
    local type=$1
    local msg=$2
    case "$type" in
        "info") echo -e "${C_CYAN}INFO:${C_RESET} $msg" ;;
        "success") echo -e "${C_GREEN}SUKSES:${C_RESET} $msg" ;;
        "warn") echo -e "${C_YELLOW}PERINGATAN:${C_RESET} $msg" ;;
        "error") echo -e "${C_RED}ERROR:${C_RESET} $msg${C_RESET}"; exit 1 ;;
        "header") echo -e "\n${C_BOLD}${C_CYAN}--- $msg ---${C_RESET}" ;;
    esac
}

run_task() {
    local description=$1
    shift
    local command_args=("$@")
    
    printf "${C_CYAN}  -> %s... ${C_RESET}" "$description"
    
    output=$("${command_args[@]}" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${C_GREEN}[OK]${C_RESET}"
        return 0
    else
        echo -e "${C_RED}[GAGAL]${C_RESET}"
        echo -e "${C_RED}==================== DETAIL ERROR ====================${C_RESET}" >&2
        echo -e "$output" >&2
        echo -e "${C_RED}====================================================${C_RESET}" >&2
        return 1
    fi
}

#--- EKSEKUSI UTAMA ---

# 1. Konfirmasi Keamanan
log "header" "KONFIRMASI PENGHAPUSAN TOTAL SEMUA CACHE"
log "warn" "Skrip ini akan melakukan tindakan berikut secara PERMANEN:"
echo -e "${C_YELLOW}  1. Menghapus konfigurasi Nginx FastCGI Cache dari semua website."
echo -e "${C_YELLOW}  2. Membersihkan (flush), menonaktifkan, dan MENGHAPUS plugin 'redis-cache' dari semua website."
echo -e "${C_YELLOW}  3. Membersihkan konstanta Redis dari file 'wp-config.php' di semua website."
echo -e "${C_YELLOW}  4. Menghapus total Redis Server dan ekstensi PHP-Redis dari server."
echo -e "${C_YELLOW}  5. Me-reload Nginx untuk menerapkan perubahan.${C_RESET}"
echo ""
read -p "Untuk melanjutkan, ketik 'SAYA YAKIN HAPUS SEMUA CACHE' lalu tekan Enter: " confirmation

if [[ "$confirmation" != "SAYA YAKIN HAPUS SEMUA CACHE" ]]; then
    log "info" "Konfirmasi tidak cocok. Operasi dibatalkan."
    exit 0
fi

# 2. Proses Setiap Website
log "header" "MEMPROSES SEMUA WEBSITE YANG TERINSTAL"
sites_dir="/etc/nginx/sites-enabled"
sites_processed=0

if [ ! -d "$sites_dir" ] || [ -z "$(ls -A "$sites_dir")" ]; then
    log "warn" "Direktori konfgurasi Nginx '$sites_dir' tidak ditemukan atau kosong."
else
    for site_symlink in "$sites_dir"/*; do
        if [ -L "$site_symlink" ] && [[ "$site_symlink" != *"default"* ]]; then
            domain=$(basename "$site_symlink")
            web_root="/var/www/$domain/public_html"
            config_file=$(readlink -f "$site_symlink") # Dapatkan path file asli

            if [ -f "$web_root/wp-config.php" ]; then
                log "info" "Memproses domain: $domain"
                
                # --- Hapus Konfigurasi Nginx FastCGI Cache ---
                if grep -q "fastcgi_cache" "$config_file"; then
                    # Menggunakan sed untuk menghapus baris-baris cache
                    sed -i '/fastcgi_cache_path/d' "$config_file"
                    sed -i '/fastcgi_cache_key/d' "$config_file"
                    sed -i '/fastcgi_cache_use_stale/d' "$config_file"
                    sed -i '/fastcgi_cache /d' "$config_file"
                    sed -i '/add_header X-Cache-Status/d' "$config_file"
                    log "success" "Konfigurasi Nginx FastCGI Cache untuk $domain telah dihapus."
                fi

                # --- Hapus Konfigurasi Redis Cache ---
                log "info" "Menghapus integrasi Redis Cache dari WordPress..."
                run_task "Flush cache Redis" sudo -u www-data wp redis flush --path="$web_root"
                run_task "Nonaktifkan plugin redis-cache" sudo -u www-data wp plugin deactivate redis-cache --path="$web_root"
                run_task "Hapus plugin redis-cache" sudo -u www-data wp plugin delete redis-cache --path="$web_root"
                
                # Bersihkan wp-config.php
                run_task "Hapus 'WP_CACHE' dari wp-config.php" sudo -u www-data wp config delete WP_CACHE --path="$web_root"
                run_task "Hapus 'WP_REDIS_HOST' dari wp-config.php" sudo -u www-data wp config delete WP_REDIS_HOST --path="$web_root"
                run_task "Hapus 'WP_REDIS_PORT' dari wp-config.php" sudo -u www-data wp config delete WP_REDIS_PORT --path="$web_root"
                
                ((sites_processed++))
            fi
        fi
    done
fi

# 3. Reload Nginx jika ada perubahan
if [ $sites_processed -gt 0 ]; then
    log "info" "Selesai memproses $sites_processed website."
    log "header" "MENERAPKAN PERUBAHAN NGINX"
    run_task "Menguji konfigurasi Nginx" nginx -t
    run_task "Me-reload layanan Nginx" systemctl reload nginx
else
    log "warn" "Tidak ada website WordPress yang diproses."
fi

# 4. Hapus Redis dari Server
log "header" "MENGHAPUS REDIS DARI SERVER"
if dpkg -s redis-server &> /dev/null; then
    php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    log "info" "Mendeteksi versi PHP default: $php_version"

    run_task "Menghentikan layanan Redis" systemctl stop redis-server
    run_task "Menonaktifkan layanan Redis" systemctl disable redis-server
    run_task "Menghapus total paket redis-server" apt-get purge -y redis-server
    if dpkg -s "php${php_version}-redis" &> /dev/null; then
        run_task "Menghapus ekstensi PHP Redis (php${php_version}-redis)" apt-get purge -y "php${php_version}-redis"
    fi
    run_task "Menghapus dependensi sisa" apt-get autoremove -y
    log "success" "Redis telah sepenuhnya dihapus dari server."
else
    log "info" "Redis server tidak terinstal. Melewati langkah ini."
fi

log "success" "PROSES PEMBERSIHAN TOTAL SEMUA CACHE TELAH SELESAI!"