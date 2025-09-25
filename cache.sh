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
        echo -e "${C_RED}==================== DETAIL ERROR ====================${C_RESET}" >&2
        echo -e "$output" >&2
        echo -e "${C_RED}====================================================${C_RESET}" >&2
        return $exit_code
    fi
}

remove_nginx_cache() {
    log "header" "MENGHAPUS KONFIGURASI NGINX CACHE"
    local config_dir="/etc/nginx/sites-enabled/"
    local domains_found=0

    # Menghapus file fastcgi_cache.conf yang sudah tidak diperlukan
    if [ -f "/etc/nginx/conf.d/fastcgi_cache.conf" ]; then
        run_task "Menghapus konfigurasi global FastCGI cache" rm "/etc/nginx/conf.d/fastcgi_cache.conf"
    fi

    for config_file in "$config_dir"/*; do
        if [ -f "$config_file" ] && [[ "$config_file" != *"default"* ]]; then
            local domain=$(basename "$config_file")
            local temp_file=$(mktemp)

            log "info" "Memproses file konfigurasi: $domain"
            
            # Hapus semua baris yang berhubungan dengan cache FastCGI
            if grep -q "fastcgi_cache WORDPRESS" "$config_file"; then
                sed '/fastcgi_cache WORDPRESS/,/add_header X-Cache-Status/d' "$config_file" > "$temp_file"
                mv "$temp_file" "$config_file"
                log "success" "Cache Nginx berhasil dihapus dari $domain."
                ((domains_found++))
            else
                log "warn" "Tidak ada konfigurasi cache Nginx yang ditemukan di $domain. Melewati."
            fi
        fi
    done

    if [ $domains_found -eq 0 ]; then
        log "warn" "Tidak ada website dengan konfigurasi cache Nginx yang ditemukan."
    else
        run_task "Menguji konfigurasi Nginx" nginx -t
        run_task "Me-reload Nginx untuk menerapkan perubahan" systemctl reload nginx
        log "success" "Proses penghapusan konfigurasi Nginx cache selesai untuk $domains_found website."
    fi
}

remove_nginx_cache