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
C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

SITES_DIR="/etc/nginx/sites-enabled"
FIX_COUNT=0
TOTAL_SITES=0

echo -e "${C_BOLD}${C_MAGENTA}--- MEMULAI PERBAIKAN SITEMAP RANK MATH UNTUK NGINX ---${C_RESET}"

if [ ! -d "$SITES_DIR" ] || [ -z "$(ls -A "$SITES_DIR")" ]; then
    echo -e "${C_YELLOW}PERINGATAN: Direktori '$SITES_DIR' tidak ditemukan atau kosong. Tidak ada yang bisa diperbaiki.${C_RESET}"
    exit 0
fi

for config_file in "$SITES_DIR"/*; do
    domain=$(basename "$config_file")
    if [[ ! -f "$config_file" ]] || [[ "$domain" == "default" ]]; then
        continue
    fi
    
    TOTAL_SITES=$((TOTAL_SITES + 1))
    echo -e "\n${C_CYAN}🔎 Memeriksa Konfigurasi: ${C_BOLD}$domain${C_RESET}"

    if ! grep -q "index.php" "$config_file"; then
        echo -e "   ${C_YELLOW}[LEWATI]${C_RESET} Sepertinya bukan situs WordPress."
        continue
    fi

    if grep -q "sitemap_index" "$config_file"; then
        echo -e "   ${C_GREEN}[OK]${C_RESET} Aturan sitemap yang benar sudah ada."
        continue
    fi
    
    if grep -q "location ~\* /wp-sitemap\.\*\\.xml" "$config_file"; then
        echo -e "   ${C_YELLOW}[MEMPERBAIKI]${C_RESET} Aturan lama ditemukan. Mengganti..."
        
        OLD_BLOCK_START="location ~\* /wp-sitemap\.\*\\.xml {"
        OLD_BLOCK_CONTENT="try_files \\\$uri \\\$uri/ /index.php\\\$is_args\\\$args;"
        NEW_BLOCK="    location ~\* /(sitemap_index|wp-sitemap).*\.xml\$ {\n        try_files \\\$uri /index.php\\\$is_args\\\$args;\n    }"

        sed -i.bak "s|${OLD_BLOCK_START}|    location ~\* /(sitemap_index|wp-sitemap).*\.xml\$ {|g" "$config_file"
        sed -i "s|${OLD_BLOCK_CONTENT}|        try_files \\\$uri /index.php\\\$is_args\\\$args;|g" "$config_file"

        echo -e "   ${C_GREEN}[SUKSES]${C_RESET} Konfigurasi untuk '$domain' telah diperbarui."
        FIX_COUNT=$((FIX_COUNT + 1))
    else
        echo -e "   ${C_YELLOW}[LEWATI]${C_RESET} Tidak ditemukan blok sitemap yang perlu diperbaiki."
    fi
done

echo -e "\n${C_BOLD}${C_MAGENTA}--- PROSES SELESAI ---${C_RESET}"
if [ "$FIX_COUNT" -gt 0 ]; then
    echo -e "${C_GREEN}✅ Total ${FIX_COUNT} dari ${TOTAL_SITES} konfigurasi situs telah diperbaiki.${C_RESET}"
    echo -e "${C_BLUE}INFO: Menguji konfigurasi Nginx...${C_RESET}"
    
    if nginx -t; then
        echo -e "${C_BLUE}INFO: Konfigurasi valid. Me-reload Nginx untuk menerapkan perubahan...${C_RESET}"
        if systemctl reload nginx; then
            echo -e "${C_GREEN}SUKSES: Nginx berhasil di-reload. Perubahan telah aktif!${C_RESET}"
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