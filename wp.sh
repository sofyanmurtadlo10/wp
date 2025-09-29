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

readonly password_file="mariadb_root_pass.txt"
declare -g mariadb_unified_pass
declare -g OS_ID OS_CODENAME PHP_VERSION PRETTY_NAME

log() {
    local type=$1
    local msg=$2
    case "$type" in
        "info") echo -e "${C_BLUE}INFO:${C_RESET} $msg" ;;
        "success") echo -e "${C_GREEN}SUKSES:${C_RESET} $msg" ;;
        "warn") echo -e "${C_YELLOW}PERINGATAN:${C_RESET} $msg" ;;
        "error") echo -e "${C_RED}ERROR:${C_RESET} $msg${C_RESET}"; exit 1 ;;
        "header") echo -e "\n${C_BOLD}${C_MAGENTA}--- $msg ---${C_RESET}" ;;
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

load_or_create_password() {
    if [ -s "$password_file" ]; then
        mariadb_unified_pass=$(cat "$password_file")
    else
        log "header" "KONFIGURASI KATA SANDI MARIADB"
        read -s -p "Masukkan kata sandi baru untuk MariaDB root: " mariadb_unified_pass; echo
        if [ -z "$mariadb_unified_pass" ]; then log "error" "Kata sandi tidak boleh kosong."; fi
        echo "$mariadb_unified_pass" > "$password_file"
        chmod 600 "$password_file"
        log "success" "Kata sandi berhasil disimpan ke '$password_file'."
    fi
}

setup_server() {
    log "header" "MEMULAI SETUP SERVER DINAMIS"

    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_ID=$ID
        OS_CODENAME=$VERSION_CODENAME
        PRETTY_NAME=$PRETTY_NAME
        log "info" "Sistem Operasi terdeteksi: $PRETTY_NAME"
        if [[ "$OS_ID" != "ubuntu" ]]; then
            log "error" "Skrip ini dioptimalkan untuk Ubuntu. OS terdeteksi: $OS_ID."
        fi
    else
        log "error" "Tidak dapat mendeteksi sistem operasi."
    fi

    run_task "Memperbarui daftar paket" apt-get update -y --allow-releaseinfo-change || log "error" "Gagal memperbarui paket."

    if ! dpkg -s software-properties-common &> /dev/null; then
        run_task "Menginstal software-properties-common" apt-get install -y software-properties-common || log "error"
    fi

    if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        log "info" "Menambahkan PPA PHP dari Ondrej Sury..."
        run_task "Menambahkan PPA ondrej/php" add-apt-repository -y ppa:ondrej/php || log "error"
        run_task "Memperbarui daftar paket lagi" apt-get update -y --allow-releaseinfo-change || log "error"
    fi

    log "header" "PILIH VERSI PHP"
    mapfile -t available_php_versions < <(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' | sed 's/-fpm//' | sort -V -r)
    if [ ${#available_php_versions[@]} -eq 0 ]; then
        log "error" "Tidak ada versi PHP yang ditemukan dari PPA."
    fi
    
    echo "Silakan pilih versi PHP yang ingin diinstal:"
    PS3="Pilih nomor: "
    select php_choice in "${available_php_versions[@]}"; do
        if [[ -n "$php_choice" ]]; then
            PHP_VERSION=$(echo "$php_choice" | sed 's/php//')
            log "info" "Anda memilih untuk menginstal PHP $PHP_VERSION."
            break
        else
            log "warn" "Pilihan tidak valid. Coba lagi."
        fi
    done

    local core_packages=(nginx mariadb-server mariadb-client unzip curl wget fail2ban)
    local php_packages=(
        "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" 
        "php${PHP_VERSION}-gd" "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-zip" 
        "php${PHP_VERSION}-intl" "php${PHP_VERSION}-bcmath"
    )
    local packages_needed=("${core_packages[@]}" "${php_packages[@]}")
    local packages_to_install=()
    for pkg in "${packages_needed[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            packages_to_install+=("$pkg")
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        run_task "Menginstal paket yang dibutuhkan" apt-get install -y "${packages_to_install[@]}" || log "error"
    else
        log "info" "Semua paket inti sudah terinstal."
    fi

    if ! command -v wp &> /dev/null; then
        run_task "Menginstal WP-CLI" wget -qO /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x /usr/local/bin/wp || log "error"
    fi

    run_task "Memulai layanan MariaDB" systemctl enable --now mariadb.service || log "error"
    load_or_create_password
    mysql -u root -p"$mariadb_unified_pass" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_unified_pass';"

    if ! ufw status | grep -q "Status: active"; then
        run_task "Mengizinkan OpenSSH di firewall" ufw allow 'OpenSSH' || log "error"
        run_task "Mengizinkan Nginx di firewall" ufw allow 'Nginx Full' || log "error"
        run_task "Mengaktifkan UFW" ufw --force enable || log "error"
    fi
    
    log "success" "Setup server selesai! Versi PHP aktif: $PHP_VERSION."
}

add_website() {
    if [ -z "$PHP_VERSION" ]; then
        log "error" "Versi PHP belum ditentukan. Jalankan 'Setup Server' (opsi 1) terlebih dahulu."
    fi

    log "header" "TAMBAH WEBSITE WORDPRESS BARU"
    load_or_create_password
    local domain web_root dbname dbuser
    
    read -p "Masukkan nama domain (contoh: domainanda.com): " domain
    
    web_root="/var/www/$domain/public_html"
    dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp
    dbuser=$(echo "$domain" | tr '.' '_' | cut -c1-16)_usr

    if [ -d "$web_root" ] || [ -f "/etc/nginx/sites-available/$domain" ]; then
        log "error" "Konflik: Direktori atau file Nginx untuk $domain sudah ada."
    fi

    run_task "Membuat database '$dbname' dan user '$dbuser'" mysql -u root -p"$mariadb_unified_pass" -e "CREATE DATABASE $dbname; CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$mariadb_unified_pass'; GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;" || log "error"
    
    run_task "Membuat direktori root dan mengatur izin" mkdir -p "$web_root" && chown -R www-data:www-data "/var/www/$domain" || log "error"
    
    run_task "Mengunduh file inti WordPress" sudo -u www-data wp core download --path="$web_root" || log "error"
    run_task "Membuat file wp-config.php" sudo -u www-data wp config create --path="$web_root" --dbname="$dbname" --dbuser="$dbuser" --dbpass="$mariadb_unified_pass" || log "error"

    log "header" "KONFIGURASI SSL (HTTPS)"
    local ssl_dir="/etc/nginx/ssl/$domain"
    run_task "Membuat direktori SSL" mkdir -p "$ssl_dir" || log "error"
    local ssl_cert_path="$ssl_dir/$domain.crt"
    local ssl_key_path="$ssl_dir/$domain.key"
    echo -e "${C_YELLOW}Tempelkan konten sertifikat (.crt), lalu simpan (Ctrl+X, Y, Enter).${C_RESET}"
    read -p "Tekan ENTER untuk membuka editor..."
    nano "$ssl_cert_path"
    echo -e "${C_YELLOW}Tempelkan konten Kunci Privat (.key), lalu simpan.${C_RESET}"
    read -p "Tekan ENTER untuk membuka editor..."
    nano "$ssl_key_path"
    if [ ! -s "$ssl_cert_path" ] || [ ! -s "$ssl_key_path" ]; then log "error" "File SSL tidak boleh kosong."; fi

    log "info" "Membuat file konfigurasi Nginx untuk '$domain'..."
    tee "/etc/nginx/sites-available/$domain" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    return 301 https://$domain\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain www.$domain;

    root $web_root;
    index index.php index.html index.htm;

    ssl_certificate $ssl_cert_path;
    ssl_certificate_key $ssl_key_path;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM";

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    client_max_body_size 100M;

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_comp_level 5;
    gzip_types application/json text/css application/x-javascript application/javascript image/svg+xml;
    gzip_proxied any;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~* /wp-sitemap.*\.xml {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~* /wp-config\.php { deny all; }
    location = /xmlrpc.php { deny all; }

    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }

    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
       access_log        off;
       log_not_found     off;
       expires           360d;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_buffers 1024 4k;
        fastcgi_buffer_size 128k;
    }
}
EOF

    run_task "Mengaktifkan site Nginx" ln -s "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/" || log "error"
    if ! run_task "Menguji konfigurasi Nginx" nginx -t; then
        log "error" "Konfigurasi Nginx tidak valid."
    fi
    run_task "Me-reload layanan Nginx" systemctl reload nginx || log "error"

    log "header" "INFORMASI ADMIN WORDPRESS"
    local site_title admin_user admin_password admin_email
    read -p "Masukkan Judul Website: " site_title
    read -p "Masukkan Username Admin: " admin_user
    read -s -p "Masukkan Password Admin: " admin_password; echo
    read -p "Masukkan Email Admin: " admin_email
    
    run_task "Menjalankan instalasi WordPress" sudo -u www-data wp core install --path="$web_root" --url="https://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email" || log "error"
    
    log "success" "Instalasi WordPress untuk 'https://$domain' selesai!"
}

list_websites() {
    log "header" "DAFTAR WEBSITE TERPASANG"
    local sites_dir="/etc/nginx/sites-enabled"
    if [ -d "$sites_dir" ] && [ -n "$(ls -A $sites_dir)" ]; then
        for site in "$sites_dir"/*; do
            if [[ "$(basename "$site")" != "default" ]]; then
                echo -e "  🌐 ${C_GREEN}$(basename "$site")${C_RESET}"
            fi
        done
    else
        log "warn" "Tidak ada website yang ditemukan."
    fi
}

delete_website() {
    log "header" "HAPUS WEBSITE (DENGAN DETEKSI PATH OTOMATIS)"
    read -p "Masukkan nama domain yang ingin dihapus (contoh: domainanda.com): " domain
    if [ -z "$domain" ]; then
        log "warn" "Nama domain kosong. Operasi dibatalkan."
        return
    fi

    local nginx_conf="/etc/nginx/sites-available/$domain"
    local nginx_symlink="/etc/nginx/sites-enabled/$domain"
    local ssl_dir="/etc/nginx/ssl/$domain"
    local web_root
    
    if [ -f "$nginx_conf" ]; then
        web_root=$(grep -oP '^\s*root\s+\K[^;]+' "$nginx_conf" | head -n 1)
    fi

    if [ -z "$web_root" ]; then
        log "warn" "Path root tidak terdeteksi. Menggunakan path standar /var/www/$domain."
        web_root="/var/www/$domain"
    else
        web_root=$(dirname "$web_root")
    fi
    
    local dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp
    local dbuser=$(echo "$domain" | tr '.' '_' | cut -c1-16)_usr

    log "warn" "Anda akan menghapus SEMUA data untuk domain '$domain' secara permanen."
    log "warn" "Tindakan ini tidak dapat dibatalkan. Direktori ${web_root} dan database ${dbname} akan dihapus."
    read -p "Apakah Anda benar-benar yakin? (y/N): " confirmation

    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log "info" "Operasi penghapusan dibatalkan."
        return
    fi

    log "info" "Memulai proses penghapusan untuk '$domain'..."
    if [ -L "$nginx_symlink" ]; then run_task "Menghapus symlink Nginx" rm "$nginx_symlink"; fi
    if [ -f "$nginx_conf" ]; then run_task "Menghapus konfigurasi Nginx" rm "$nginx_conf"; fi
    run_task "Me-reload Nginx" systemctl reload nginx

    if [ -d "$web_root" ]; then
        run_task "Menghapus direktori web '$web_root'" rm -rf "$web_root"
    fi
    
    if [ -d "$ssl_dir" ]; then run_task "Menghapus direktori SSL" rm -rf "$ssl_dir"; fi

    load_or_create_password
    if mysql -u root -p"$mariadb_unified_pass" -e "USE $dbname;" &>/dev/null; then
        run_task "Menghapus database '$dbname'" mysql -u root -p"$mariadb_unified_pass" -e "DROP DATABASE IF EXISTS $dbname;"
        run_task "Menghapus user database '$dbuser'" mysql -u root -p"$mariadb_unified_pass" -e "DROP USER IF EXISTS '$dbuser'@'localhost';"
        run_task "Memuat ulang hak akses" mysql -u root -p"$mariadb_unified_pass" -e "FLUSH PRIVILEGES;"
    fi
    log "success" "Semua data untuk domain '$domain' telah berhasil dihapus."
}

show_menu() {
    clear
    echo -e "${C_BOLD}${C_MAGENTA}=========================================================="
    echo "         🚀 SCRIPT MANAJEMEN WORDPRESS DINAMIS 🚀       "
    echo "=========================================================="
    echo -e "${C_RESET}"
    echo -e "  OS: ${C_CYAN}${PRETTY_NAME:-Belum Terdeteksi}${C_RESET} | PHP: ${C_CYAN}${PHP_VERSION:-Belum Dipilih}${C_RESET}"
    echo ""
    echo -e "  ${C_GREEN}1. Setup Awal Server (Deteksi OS & PHP Otomatis) ⚙️${C_RESET}"
    echo -e "  ${C_CYAN}2. Tambah Website WordPress Baru ➕${C_RESET}"
    echo -e "  ${C_YELLOW}3. Lihat Daftar Website Terpasang 📜${C_RESET}"
    echo -e "  ${C_RED}4. Hapus Website 🗑️${C_RESET}"
    echo -e "  ${C_BLUE}5. Keluar 🚪${C_RESET}"
    echo ""
}

main() {
    while true; do
        show_menu
        read -p "Pilih opsi [1-5]: " choice
        case $choice in
            1) setup_server ;;
            2) add_website ;;
            3) list_websites ;;
            4) delete_website ;;
            5) log "info" "Terima kasih! 👋"; exit 0 ;;
            *) log "warn" "Pilihan tidak valid."; sleep 2 ;;
        esac
        echo
        read -n 1 -s -r -p "Tekan tombol apapun untuk kembali ke menu..."
    done
}

main