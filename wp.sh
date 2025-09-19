#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
   echo "❌ Kesalahan: Skrip ini harus dijalankan sebagai root. Coba 'sudo bash $0'" 
   exit 1
fi

C_RESET='\e[0m'
C_BOLD='\e[1m'
C_DIM='\e[2m'
C_RED='\e[31m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_BLUE='\e[34m'
C_MAGENTA='\e[35m'
C_CYAN='\e[36m'
C_GRAY='\e[90m'
C_WHITE='\e[97m'
S_SUCCESS="${C_GREEN}✓${C_RESET}"
S_FAIL="${C_RED}✗${C_RESET}"
S_INFO="${C_BLUE}ℹ${C_RESET}"
S_WARN="${C_YELLOW}⚠${C_RESET}"
S_RUN="${C_CYAN}›${C_RESET}"
S_INPUT="${C_CYAN}›${C_RESET}"

readonly password_file="mariadb_root_pass.txt"
declare -g mariadb_unified_pass

print_header() {
    local title=" $1 "
    local term_width=$(tput cols)
    local title_len=${#title}
    local padding_len=$(( (term_width - title_len) / 2 ))
    local padding=""
    for (( i=0; i<padding_len; i++ )); do padding+="─"; done
    echo -e "\n${C_BOLD}${C_MAGENTA}╭${padding}${title}${padding}╮${C_RESET}"
}

log() {
    case "$1" in
        "info")    echo -e " ${S_INFO}  $2" ;;
        "success") echo -e " ${S_SUCCESS}  ${C_GREEN}$2${C_RESET}" ;;
        "warn")    echo -e " ${S_WARN}  ${C_YELLOW}$2${C_RESET}" ;;
        "error")   echo -e " ${S_FAIL}  ${C_RED}$2${C_RESET}"; exit 1 ;;
    esac
}

run_task() {
    local description=$1
    shift
    local command_args=("$@")
    
    echo -en " ${S_RUN}  ${C_DIM}$description...${C_RESET}"
    
    output=$("${command_args[@]}" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "\r ${S_SUCCESS}  ${description}... ${C_GREEN}selesai.${C_RESET}"
        return 0
    else
        echo -e "\r ${S_FAIL}  ${description}... ${C_RED}gagal.${C_RESET}"
        echo -e "${C_RED}╭─[ Detail Error ]──────────────────────────────────────────╮${C_RESET}" >&2
        while IFS= read -r line; do
            echo -e "${C_RED}│${C_RESET} $line" >&2
        done <<< "$output"
        echo -e "${C_RED}╰────────────────────────────────────────────────────────────╯${C_RESET}" >&2
        log "error" "Skrip dihentikan karena terjadi kesalahan."
    fi
}

load_or_create_password() {
    if [ -s "$password_file" ]; then
        mariadb_unified_pass=$(cat "$password_file")
    else
        print_header "Setup Kata Sandi MariaDB"
        echo -e " ${S_INFO}  Kata sandi ini akan disimpan di ${C_BOLD}$password_file${C_RESET} untuk penggunaan selanjutnya."
        read -s -p "  ${S_INPUT}  Masukkan kata sandi baru untuk 'root' MariaDB: " mariadb_unified_pass; echo
        if [ -z "$mariadb_unified_pass" ]; then log "error" "Kata sandi tidak boleh kosong."; fi
        echo "$mariadb_unified_pass" > "$password_file" && chmod 600 "$password_file"
        log "success" "Kata sandi berhasil dibuat dan disimpan."
    fi
}

setup_server() {
    print_header "1. Setup Server Awal"
    log "info" "Memeriksa dan menginstal semua dependensi yang diperlukan."

    run_task "Memperbarui daftar paket" apt-get update -y
    if ! dpkg -s software-properties-common &>/dev/null; then
        run_task "Menginstal software-properties-common" apt-get install -y software-properties-common
    fi
    if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        run_task "Menambahkan PPA PHP ondrej/php" add-apt-repository -y ppa:ondrej/php
        run_task "Memperbarui daftar paket setelah menambah PPA" apt-get update -y
    fi
    
    packages_needed=(nginx mariadb-server mariadb-client unzip curl wget fail2ban redis-server php8.3-fpm php8.3-mysql php8.3-xml php8.3-curl php8.3-gd php8.3-imagick php8.3-mbstring php8.3-zip php8.3-intl php8.3-bcmath php8.3-redis)
    packages_to_install=()
    for pkg in "${packages_needed[@]}"; do if ! dpkg -s "$pkg" &>/dev/null; then packages_to_install+=("$pkg"); fi; done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        run_task "Menginstal paket inti" apt-get install -y "${packages_to_install[@]}"
    else
        log "info" "Semua paket inti sudah terinstal."
    fi

    if ! command -v wp &>/dev/null; then
        run_task "Mengunduh WP-CLI" wget -nv https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /usr/local/bin/wp
        run_task "Memberikan izin eksekusi WP-CLI" chmod +x /usr/local/bin/wp
    else
        log "info" "WP-CLI sudah terinstal."
    fi

    if ! systemctl is-active --quiet mariadb; then
        run_task "Mengaktifkan layanan MariaDB" systemctl enable --now mariadb.service
    fi
    load_or_create_password
    run_task "Mengamankan instalasi MariaDB" mysql -u root -p"$mariadb_unified_pass" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_unified_pass';"
    
    if [ ! -f "/etc/nginx/conf.d/fastcgi_cache.conf" ]; then
        run_task "Membuat konfigurasi Nginx FastCGI Cache" tee /etc/nginx/conf.d/fastcgi_cache.conf >/dev/null <<< "fastcgi_cache_path /var/run/nginx-cache levels=1:2 keys_zone=WORDPRESS:100m inactive=60m; fastcgi_cache_key \"\$scheme\$request_method\$host\$request_uri\";"
    fi

    if ! ufw status | grep -q "Status: active"; then
        run_task "Mengonfigurasi firewall (UFW)" ufw allow 'OpenSSH' && ufw allow 'Nginx Full' && ufw --force enable
    else
        log "info" "Firewall UFW sudah aktif."
    fi
    log "success" "Setup server selesai. Sistem telah siap."
}

add_website() {
    print_header "2. Tambah Website WordPress Baru"
    if ! command -v wp &>/dev/null; then log "error" "WP-CLI tidak ditemukan. Jalankan 'Setup Server' dahulu."; fi
    load_or_create_password

    local domain dbname dbuser web_root site_title admin_user admin_password admin_email

    echo -e " ${S_INFO}  Masukkan detail untuk website WordPress baru Anda."
    read -p "  ${S_INPUT}  Domain (contoh: domain.com): " domain
    while ! [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; do
        log "warn" "Format domain tidak valid. Silakan coba lagi."
        read -p "  ${S_INPUT}  Domain (contoh: domain.com): " domain
    done

    web_root="/var/www/$domain/public_html"
    dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp
    dbuser=$(echo "$domain" | tr '.' '_' | cut -c1-16)_usr

    if [ -d "/var/www/$domain" ] || [ -f "/etc/nginx/sites-available/$domain" ] || mysql -u root -p"$mariadb_unified_pass" -e "USE $dbname;" &>/dev/null; then
        log "error" "Website atau database untuk '$domain' sudah ada. Hapus dahulu jika ingin melanjutkan."
    fi

    run_task "Membuat database '$dbname' dan user '$dbuser'" mysql -u root -p"$mariadb_unified_pass" -e "CREATE DATABASE $dbname; CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$mariadb_unified_pass'; GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;"
    run_task "Membuat direktori website" mkdir -p "$web_root"
    run_task "Menyesuaikan izin direktori" chown -R www-data:www-data "/var/www/$domain"
    run_task "Mengunduh file inti WordPress" sudo -u www-data --set-home wp core download --path="$web_root"
    run_task "Membuat file wp-config.php" sudo -u www-data --set-home wp config create --path="$web_root" --dbname="$dbname" --dbuser="$dbuser" --dbpass="$mariadb_unified_pass" --extra-php <<< "define('WP_CACHE', true); define('WP_REDIS_HOST', '127.0.0.1'); define('WP_REDIS_PORT', 6379);"

    echo -e " ${S_INFO}  Anda perlu menyediakan sertifikat SSL untuk HTTPS."
    local ssl_dir="/etc/nginx/ssl/$domain" && mkdir -p "$ssl_dir"
    local ssl_cert_path="$ssl_dir/$domain.crt"
    local ssl_key_path="$ssl_dir/$domain.key"
    echo "  Buka editor untuk menempelkan isi file sertifikat (.crt)..."
    read -p "  Tekan ENTER untuk melanjutkan."
    nano "$ssl_cert_path"
    echo "  Buka editor untuk menempelkan isi file kunci privat (.key)..."
    read -p "  Tekan ENTER untuk melanjutkan."
    nano "$ssl_key_path"
    if [ ! -s "$ssl_cert_path" ] || [ ! -s "$ssl_key_path" ]; then log "error" "File SSL tidak boleh kosong. Instalasi dibatalkan."; fi

    tee "/etc/nginx/sites-available/$domain" > /dev/null <<EOF
server {
    listen 80; listen [::]:80; server_name $domain www.$domain; return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; listen [::]:443 ssl http2;
    server_name $domain www.$domain;
    root $web_root;
    index index.php;

    rewrite ^/sitemap_index\.xml$ /index.php?sitemap=1 last;
    rewrite ^/([^/]+?)-sitemap([0-9]+)?\.xml$ /index.php?sitemap=\$1&sitemap_n=\$2 last;
    rewrite ^/sitemap\.xsl$ /index.php?sitemap_xsl=1 last;

    ssl_certificate $ssl_cert_path; ssl_certificate_key $ssl_key_path;
    ssl_protocols TLSv1.2 TLSv1.3; ssl_prefer_server_ciphers on;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM";
    add_header Strict-Transport-Security "max-age=63072000" always;

    client_max_body_size 100M;
    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|sitemap(_index)?.xml") { set \$skip_cache 1; }
    if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") { set \$skip_cache 1; }

    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 60m;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
    }
    location ~ /\.ht { deny all; }
}
EOF
    run_task "Mengaktifkan konfigurasi Nginx" ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/"
    run_task "Memuat ulang Nginx" systemctl reload nginx

    echo -e " ${S_INFO}  Masukkan detail untuk akun admin WordPress."
    read -p "  ${S_INPUT}  Judul Website: " site_title
    read -p "  ${S_INPUT}  Username Admin: " admin_user
    read -s -p "  ${S_INPUT}  Password Admin: " admin_password; echo
    read -p "  ${S_INPUT}  Email Admin: " admin_email
    run_task "Menyelesaikan instalasi WordPress" sudo -u www-data --set-home wp core install --path="$web_root" --url="https://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email"
    run_task "Menginstal plugin-plugin" sudo -u www-data --set-home wp plugin install redis-cache wp-file-manager instant-indexing-api disable-comments-rb floating-ads-bottom post-views-counter seo-by-rank-math --activate --path="$web_root"
    run_task "Mengaktifkan Redis Object Cache" sudo -u www-data --set-home wp redis enable --path="$web_root"

    echo -e "${C_GREEN}╭─[ Instalasi Selesai ]──────────────────────────────────╮"
    echo -e "│                                                         │"
    echo -e "│  ${C_BOLD}${C_WHITE}Website Anda siap diakses!${C_RESET}                           │"
    echo -e "│                                                         │"
    echo -e "│  URL Login : ${C_CYAN}https://$domain/wp-admin/${C_RESET}               │"
    echo -e "│  Username  : ${C_CYAN}$admin_user${C_RESET}                                   │"
    echo -e "│  Password  : (Yang baru saja Anda masukkan)             │"
    echo -e "│                                                         │"
    echo -e "╰─────────────────────────────────────────────────────────╯${C_RESET}"
}

list_websites() {
    print_header "3. Daftar Website Terpasang"
    local sites_dir="/etc/nginx/sites-enabled"
    local count=0
    if [ -d "$sites_dir" ] && [ "$(ls -A $sites_dir)" ]; then
        for site in $(ls -A $sites_dir); do
            if [ "$site" != "default" ]; then
                echo -e "  ${C_MAGENTA}🌐 ${C_WHITE}${site}${C_RESET} ${C_GRAY}(https://$site)${C_RESET}"
                count=$((count+1))
            fi
        done
    fi
    if [ $count -eq 0 ]; then
        log "info" "Tidak ada website yang ditemukan."
    fi
}

delete_website() {
    print_header "4. Hapus Website"
    read -p "  ${S_INPUT}  Masukkan nama domain yang akan dihapus: " domain
    if [ -z "$domain" ]; then log "warn" "Nama domain kosong. Operasi dibatalkan."; return; fi

    local web_root="/var/www/$domain"
    local nginx_conf="/etc/nginx/sites-available/$domain"
    local ssl_dir="/etc/nginx/ssl/$domain"
    local dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp

    echo -e "${C_RED}╭─[ PERINGATAN ]───────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_RED}│${C_RESET} Anda akan ${C_BOLD}MENGHAPUS SELURUH DATA${C_RESET} untuk domain ${C_BOLD}$domain${C_RESET}.  ${C_RED}│"
    echo -e "${C_RED}│${C_RESET} Termasuk file web, database, dan sertifikat SSL.         ${C_RED}│"
    echo -e "${C_RED}│${C_RESET} ${C_BOLD}TINDAKAN INI TIDAK BISA DIURUNGKAN!${C_RESET}                      ${C_RED}│"
    echo -e "${C_RED}╰────────────────────────────────────────────────────────────╯${C_RESET}"
    read -p "  ${S_INPUT}  Ketik '${C_YELLOW}$domain${C_RESET}' untuk konfirmasi penghapusan: " confirmation

    if [ "$confirmation" != "$domain" ]; then log "info" "Konfirmasi salah. Operasi dibatalkan."; return; fi
    
    log "info" "Memulai proses penghapusan untuk '$domain'..."
    if [ -f "/etc/nginx/sites-enabled/$domain" ]; then run_task "Menonaktifkan site Nginx" rm "/etc/nginx/sites-enabled/$domain"; fi
    if [ -f "$nginx_conf" ]; then run_task "Menghapus konfigurasi Nginx" rm "$nginx_conf"; fi
    run_task "Memuat ulang Nginx" systemctl reload nginx
    if [ -d "$web_root" ]; then run_task "Menghapus file website" rm -rf "$web_root"; fi
    if [ -d "$ssl_dir" ]; then run_task "Menghapus sertifikat SSL" rm -rf "$ssl_dir"; fi
    if mysql -u root -p"$mariadb_unified_pass" -e "USE $dbname;" &>/dev/null; then
        run_task "Menghapus database" mysql -u root -p"$mariadb_unified_pass" -e "DROP DATABASE $dbname;"
    fi
    log "success" "Semua data untuk domain '$domain' telah dihapus."
}

show_menu() {
    clear
    local term_width=$(tput cols)
    local title=" PENGELOLA SERVER WORDPRESS "
    local title_len=${#title}
    local padding_len=$(( (term_width - title_len - 2) / 2 ))
    local padding=""
    for (( i=0; i<padding_len; i++ )); do padding+="─"; done

    echo -e "${C_BOLD}${C_BLUE}╭${padding}${title}${padding}╮${C_RESET}"
    echo -e "   ${C_CYAN}[1]${C_RESET}  Setup Server Awal      ${C_GRAY}› Instal dependensi inti (Nginx, PHP, dll)${C_RESET}"
    echo -e "   ${C_CYAN}[2]${C_RESET}  Tambah Website Baru    ${C_GRAY}› Buat instalasi WordPress yang baru${C_RESET}"
    echo -e "   ${C_CYAN}[3]${C_RESET}  Lihat Daftar Website   ${C_GRAY}› Tampilkan semua website yang terpasang${C_RESET}"
    echo -e "   ${C_CYAN}[4]${C_RESET}  Hapus Website          ${C_GRAY}› Hapus website, database, dan konfigurasinya${C_RESET}"
    echo -e "   ${C_CYAN}[5]${C_RESET}  Keluar                 ${C_GRAY}› Tutup skrip ini${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}╰${padding}──────────────────${padding}╯${C_RESET}"
}

main() {
    while true; do
        show_menu
        read -p " ${S_INPUT}  Pilih Opsi [1-5]: " choice
        case $choice in
            1) setup_server ;;
            2) add_website ;;
            3) list_websites ;;
            4) delete_website ;;
            5) log "info" "Terima kasih telah menggunakan skrip ini. Sampai jumpa!"; exit 0 ;;
            *) log "warn" "Pilihan tidak valid." ;;
        esac
        echo -e "\n ${S_INFO}  Tekan tombol apa saja untuk kembali ke menu utama..."
        read -n 1 -s -r
    done
}

main