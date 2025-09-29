#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    echo "❌ Kesalahan: Skrip ini harus dijalankan sebagai root. Coba 'sudo bash $0'"
    exit 1
fi

C_RESET='\e[0m'
C_RED='\e[1;31m'
C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m'
C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

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
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                echo -e "${C_YELLOW}     ↳ ${line}${C_RESET}" >&2
            fi
        done <<< "$output"
        return 1
    fi
}

main() {
    log "header" "MEMULAI PENGHAPUSAN TOTAL SEMUA CACHE (VERSI AGGRESIF)"

    log "header" "MEMPROSES SEMUA WEBSITE (FILE & SYMLINK)"
    local sites_dir="/etc/nginx/sites-enabled"
    local sites_processed=0

    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A "$sites_dir")" ]; then
        log "warn" "Direktori konfgurasi Nginx '$sites_dir' tidak ditemukan atau kosong."
    else
        for site_config in "$sites_dir"/*; do
            if [ -f "$site_config" ] && [[ "$(basename "$site_config")" != "default" ]]; then
                local domain=$(basename "$site_config")
                local real_config_file=$(readlink -f "$site_config")
                local web_root=$(grep -oP '^\s*root\s+\K[^;]+' "$real_config_file" | head -n 1)

                if [ -z "$web_root" ]; then
                    log "warn" "Tidak dapat menemukan direktori 'root' untuk domain $domain. Melanjutkan..."
                    continue
                fi
                
                if [ -f "$web_root/wp-config.php" ]; then
                    log "info" "Memproses domain: $domain | Path: $web_root"
                    local site_has_error=0
                    
                    # --- PENGHAPUSAN MANUAL & PAKSA ---
                    if [ -f "$web_root/wp-content/object-cache.php" ]; then
                        run_task "Menghapus paksa object-cache.php" rm -f "$web_root/wp-content/object-cache.php" || site_has_error=1
                    fi

                    if [ -d "$web_root/wp-content/plugins/redis-cache" ]; then
                        run_task "Menghapus paksa direktori plugin redis-cache" rm -rf "$web_root/wp-content/plugins/redis-cache" || site_has_error=1
                    fi

                    # Menjalankan perintah WP-CLI sebagai pembersihan akhir
                    run_task "Flush cache" sudo -u www-data wp cache flush --path="$web_root"
                    run_task "Hapus 'WP_CACHE' dari wp-config.php" sudo -u www-data wp config delete WP_CACHE --path="$web_root"
                    run_task "Hapus 'WP_REDIS_HOST' dari wp-config.php" sudo -u www-data wp config delete WP_REDIS_HOST --path="$web_root"
                    run_task "Hapus 'WP_REDIS_PORT' dari wp-config.php" sudo -u www-data wp config delete WP_REDIS_PORT --path="$web_root"

                    # Nonaktifkan Nginx Cache
                    if grep -q "fastcgi_cache" "$real_config_file" && ! grep -q "#fastcgi_cache" "$real_config_file"; then
                        sed -i -E '/fastcgi_cache_path|fastcgi_cache_key|fastcgi_cache_use_stale|fastcgi_cache |add_header X-Cache-Status/s/^(\s*)/#\1/' "$real_config_file"
                        log "success" "Konfigurasi Nginx FastCGI Cache untuk $domain telah dinonaktifkan."
                    fi
                    
                    if [ $site_has_error -ne 0 ]; then
                        log "warn" "Terjadi kegagalan saat memproses $domain. Melanjutkan ke website berikutnya."
                    else
                        log "success" "Domain $domain berhasil diproses."
                    fi
                    ((sites_processed++))
                fi
            fi
        done
    fi

    if [ $sites_processed -gt 0 ]; then
        log "info" "Selesai memproses $sites_processed website."
        log "header" "MENERAPKAN PERUBAHAN NGINX"
        if ! run_task "Menguji konfigurasi Nginx" nginx -t; then
             log "error" "Konfigurasi Nginx tidak valid. Perubahan belum diterapkan."
        fi
        run_task "Me-reload layanan Nginx" systemctl reload nginx || log "error" "Gagal me-reload Nginx."
    else
        log "warn" "Tidak ada website WordPress yang diproses."
    fi

    log "header" "MENGHAPUS REDIS DARI SERVER"
    if dpkg -s redis-server &> /dev/null; then
        local php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
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
}

main