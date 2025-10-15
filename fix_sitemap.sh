#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    echo "❌ Kesalahan: Skrip ini harus dijalankan sebagai root. Coba 'sudo bash $0'"
    exit 1
fi

C_RESET='\e[0m'
C_RED='\e[1;31m'
C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m'
C_BLUE='\e[1;34m'
C_MAGENTA='\e[1;35m'
C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

SITES_DIR="/etc/nginx/sites-enabled"
FIX_COUNT=0
TOTAL_SITES=0

SITEMAP_BLOCK="
    rewrite ^/sitemap\\.xml\$ /index.php?sitemap=1 last;
    rewrite ^/sitemap_index\\.xml\$ /index.php?sitemap=1 last;
    rewrite ^/([^/]+?)-sitemap([0-9]+)?\\.xml\$ /index.php?sitemap=\$1&sitemap_n=\$2 last;
    rewrite ^/([a-z]+)?-sitemap\\.xsl\$ /index.php?xsl=\$1 last;
"

log() {
    local type=$1
    local msg=$2
    case "$type" in
        "info") echo -e "${C_BLUE}INFO:${C_RESET} $msg" ;;
        "success") echo -e "${C_GREEN}SUKSES:${C_RESET} $msg" ;;
        "warn") echo -e "${C_YELLOW}PERINGATAN:${C_RESET} $msg" ;;
        "error") echo -e "${C_RED}ERROR:${C_RESET} $msg${C_RESET}"; exit 1 ;;
    esac
}

run_task() {
    local description=$1
    shift
    local command_args=("$@")
    
    printf "${C_CYAN}   -> %s... ${C_RESET}" "$description"
    
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

ensure_nginx_limit_req_zone() {
    local nginx_conf="/etc/nginx/nginx.conf"
    if [ ! -f "$nginx_conf" ]; then
        log "warn" "File konfigurasi Nginx utama ($nginx_conf) tidak ditemukan. Melewati pemeriksaan limit_req_zone."
        return
    fi

    if ! grep -q "limit_req_zone.*mylimit" "$nginx_conf"; then
        log "warn" "Konfigurasi limit_req_zone tidak ditemukan. Menambahkan secara otomatis..."
        if ! run_task "Menambahkan limit_req_zone ke $nginx_conf" \
            sed -i '/http {/a \    limit_req_zone $binary_remote_addr zone=mylimit:10m rate=10r/s;' "$nginx_conf"; then
            log "error" "Gagal menambahkan limit_req_zone ke file konfigurasi Nginx."
        fi
    fi
}

echo -e "${C_BOLD}${C_MAGENTA}--- MEMULAI PERBAIKAN SITEMAP & KONFIGURASI NGINX ---${C_RESET}"

ensure_nginx_limit_req_zone

if [ ! -d "$SITES_DIR" ] || [ -z "$(ls -A "$SITES_DIR")" ]; then
    echo -e "${C_YELLOW}PERINGATAN: Direktori '$SITES_DIR' tidak ditemukan atau kosong. Tidak ada yang bisa diperbaiki.${C_RESET}"
    exit 0
fi

for config_file in "$SITES_DIR"/*; do
    domain=$(basename "$config_file")
    
    if [[ "$config_file" == *.bak ]]; then
        continue
    fi

    if [[ ! -f "$config_file" ]] || [[ "$domain" == "default" ]]; then
        continue
    fi
    
    TOTAL_SITES=$((TOTAL_SITES + 1))
    echo -e "\n${C_CYAN}🔎 Memeriksa Konfigurasi: ${C_BOLD}$domain${C_RESET}"

    if ! grep -q "try_files.*index.php" "$config_file"; then
        echo -e "   ${C_YELLOW}[LEWATI]${C_RESET} Sepertinya bukan situs WordPress."
        continue
    fi

    CONFIG_IS_OK=true
    if ! grep -q "rewrite ^/sitemap\.xml" "$config_file" || ! grep -q "rewrite ^/sitemap_index\.xml" "$config_file"; then
        CONFIG_IS_OK=false
    fi
    if ! grep -q "access_log /var/log/nginx/$domain/access.log;" "$config_file"; then
        CONFIG_IS_OK=false
    fi
    if ! grep -q "limit_req zone=mylimit" "$config_file"; then
        CONFIG_IS_OK=false
    fi

    if $CONFIG_IS_OK; then
        echo -e "   ${C_GREEN}[OK]${C_RESET} Konfigurasi sudah sesuai standar terbaru."
        continue
    fi
    
    echo -e "   ${C_YELLOW}[MEMPERBAIKI]${C_RESET} Konfigurasi lama terdeteksi. Meng-upgrade..."
    
    cp "$config_file" "${config_file}.bak"
    echo -e "   ${C_BLUE}[INFO]${C_RESET} Cadangan dibuat di ${config_file}.bak"

    sed -i '/location ~\* \/(sitemap_index|wp-sitemap)/,/\}/d' "$config_file"
    sed -i '/rewrite ^\/sitemap_index/d' "$config_file"
    sed -i '/rewrite ^\/sitemap\.xml/d' "$config_file"
    sed -i '/rewrite ^\/([^/]+?)-sitemap/d' "$config_file"
    sed -i '/rewrite ^\/([a-z]+)?-sitemap/d' "$config_file"

    awk -i inplace -v block="$SITEMAP_BLOCK" '1; /ssl_certificate_key/ { if (!printed) { print block; printed=1 } }' "$config_file"
    
    if ! grep -q "access_log /var/log/nginx/$domain" "$config_file"; then
        mkdir -p "/var/log/nginx/$domain"
        sed -i "/root /a \ \n    access_log /var/log/nginx/$domain/access.log;\n    error_log /var/log/nginx/$domain/error.log;" "$config_file"
    fi

    if ! grep -q "limit_req zone=mylimit" "$config_file"; then
        sed -i '/location \/ {/a \        limit_req zone=mylimit burst=20 nodelay;\n        limit_conn addr 10;' "$config_file"
    fi

    echo -e "   ${C_GREEN}[SUKSES]${C_RESET} Konfigurasi untuk '$domain' telah di-upgrade."
    FIX_COUNT=$((FIX_COUNT + 1))
done

echo -e "\n${C_BOLD}${C_MAGENTA}--- PROSES SELESAI ---${C_RESET}"
if [ "$FIX_COUNT" -gt 0 ]; then
    echo -e "${C_GREEN}✅ Total ${FIX_COUNT} dari ${TOTAL_SITES} konfigurasi situs telah diperbaiki/di-upgrade.${C_RESET}"
    echo -e "${C_BLUE}INFO: Menguji konfigurasi Nginx...${C_RESET}"
    
    if nginx -t; then
        echo -e "${C_BLUE}INFO: Konfigurasi valid. Me-reload Nginx untuk menerapkan perubahan...${C_RESET}"
        if systemctl reload nginx; then
            echo -e "${C_GREEN}SUKSES: Nginx berhasil di-reload. Konfigurasi baru telah aktif!${C_RESET}"
        else
            echo -e "${C_RED}ERROR: Gagal me-reload Nginx. Cek status layanan dengan 'systemctl status nginx'.${C_RESET}"
        fi
    else
        echo -e "${C_RED}ERROR: Tes konfigurasi Nginx GAGAL. Perubahan BELUM diterapkan.${C_RESET}"
        echo -e "${C_YELLOW}Periksa detail error di atas. File konfigurasi asli telah dicadangkan dengan ekstensi .bak${C_RESET}"
    fi
else
    echo -e "${C_GREEN}Tidak ada konfigurasi yang perlu diubah. Semua sudah sesuai.${C_RESET}"
fi