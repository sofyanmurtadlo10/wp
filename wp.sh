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

detect_os_php() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_ID=$ID
        OS_CODENAME=$VERSION_CODENAME
        PRETTY_NAME=$PRETTY_NAME
        if [[ "$OS_ID" != "ubuntu" ]]; then
            log "error" "Skrip ini dioptimalkan untuk Ubuntu. OS terdeteksi: $OS_ID."
        fi
    else
        log "error" "Tidak dapat mendeteksi sistem operasi."
    fi

    case "$OS_CODENAME" in
        "noble") PHP_VERSION="8.3" ;;
        "jammy") PHP_VERSION="8.1" ;;
        "focal") PHP_VERSION="7.4" ;;
        *) PHP_VERSION="Tidak Didukung" ;;
    esac
}

prompt_input() {
    local message=$1
    local var_name=$2
    local is_secret=false
    if [[ "$3" == "-s" ]]; then
        is_secret=true
    fi

    local prompt_text="${C_CYAN}❓ ${message}:${C_RESET} "
    
    while true; do
        local user_input
        printf "%b" "$prompt_text"
        if $is_secret; then
            read -s user_input
            echo
        else
            read user_input
        fi
        
        user_input_sanitized="${user_input// /}"

        if [[ -n "$user_input_sanitized" ]]; then
            eval "$var_name"="'$user_input_sanitized'"
            break
        else
            echo -e "${C_RED}Input tidak boleh kosong. Silakan coba lagi.${C_RESET}"
        fi
    done
}

load_or_create_password() {
    if [ -s "$password_file" ]; then
        mariadb_unified_pass=$(cat "$password_file")
    else
        log "header" "KONFIGURASI KATA SANDI MARIADB"
        prompt_input "Kata sandi baru untuk MariaDB root" mariadb_unified_pass -s
        echo "$mariadb_unified_pass" > "$password_file"
        chmod 600 "$password_file"
        log "success" "Kata sandi berhasil disimpan ke '$password_file'."
    fi
}

setup_server() {
    log "header" "MEMULAI SETUP SERVER"
    log "info" "Menggunakan OS terdeteksi: $PRETTY_NAME"
    if [[ "$PHP_VERSION" == "Tidak Didukung" ]]; then
        log "error" "Versi Ubuntu '$OS_CODENAME' tidak didukung secara otomatis oleh skrip ini."
    fi
    log "success" "Versi PHP yang akan digunakan untuk $OS_CODENAME: PHP $PHP_VERSION"

    run_task "Memperbarui daftar paket" apt-get update -y --allow-releaseinfo-change || log "error" "Gagal memperbarui paket."

    if ! dpkg -s software-properties-common &> /dev/null; then
        run_task "Menginstal software-properties-common" apt-get install -y software-properties-common || log "error"
    fi

    if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        log "info" "Menambahkan PPA PHP dari Ondrej Sury..."
        run_task "Menambahkan PPA ondrej/php" add-apt-repository -y ppa:ondrej/php || log "error"
        run_task "Memperbarui daftar paket lagi" apt-get update -y --allow-releaseinfo-change || log "error"
    fi

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
        run_task "Menginstal paket yang dibutuhkan (PHP $PHP_VERSION)" apt-get install -y "${packages_to_install[@]}" || log "error"
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

generate_db_credentials() {
    local domain=$1
    local suffix=$2
    local domain_part
    domain_part=$(echo "$domain" | tr '.' '_' | cut -c1-10)
    local hash_part
    hash_part=$(echo -n "$domain" | md5sum | cut -c1-5)
    echo "${domain_part}_${hash_part}${suffix}"
}

add_website() {
    if [[ "$PHP_VERSION" == "Tidak Didukung" ]]; then
        log "error" "Tidak dapat menambah website karena versi Ubuntu '$OS_CODENAME' tidak didukung."
    fi

    log "header" "TAMBAH WEBSITE WORDPRESS BARU"
    load_or_create_password
    local domain web_root dbname dbuser
    
    prompt_input "Nama domain (contoh: domainanda.com)" domain
    
    web_root="/var/www/$domain/public_html"
    dbname=$(generate_db_credentials "$domain" "_wp")
    dbuser=$(generate_db_credentials "$domain" "_usr")

    if [ -f "/etc/nginx/sites-enabled/$domain" ]; then
        log "error" "Konflik: File konfigurasi Nginx untuk $domain sudah ada di sites-enabled."
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
    
    log "info" "Selanjutnya, editor teks 'nano' akan terbuka untuk Anda."
    echo -e "${C_YELLOW}   -> Tempelkan konten sertifikat (.crt), lalu simpan (Ctrl+X, Y, Enter).${C_RESET}"
    read -p "   Tekan ENTER untuk melanjutkan..."
    nano "$ssl_cert_path"
    
    echo -e "${C_YELLOW}   -> Tempelkan konten Kunci Privat (.key), lalu simpan.${C_RESET}"
    read -p "   Tekan ENTER untuk melanjutkan..."
    nano "$ssl_key_path"

    if [ ! -s "$ssl_cert_path" ] || [ ! -s "$ssl_key_path" ]; then log "error" "File SSL tidak boleh kosong."; fi

    log "info" "Membuat file konfigurasi Nginx untuk '$domain' langsung di sites-enabled..."
    tee "/etc/nginx/sites-enabled/$domain" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain www.$domain;

    root $web_root;
    index index.php;

    ssl_certificate $ssl_cert_path;
    ssl_certificate_key $ssl_key_path;

    rewrite ^/sitemap_index\.xml$ /index.php?sitemap=1 last;
    rewrite ^/([^/]+?)-sitemap([0-9]+)?\.xml$ /index.php?sitemap=\$1&sitemap_n=\$2 last;
    rewrite ^/([a-z]+)?-sitemap\.xsl$ /index.php?xsl=\$1 last;

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

    location ~* /wp-config\.php { deny all; }
    location = /xmlrpc.php { deny all; }

    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }

    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
       access_log         off;
       log_not_found      off;
       expires            360d;
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

    if ! run_task "Menguji konfigurasi Nginx" nginx -t; then
        log "error" "Konfigurasi Nginx tidak valid."
    fi
    run_task "Me-reload layanan Nginx" systemctl reload nginx || log "error"

    log "header" "INFORMASI ADMIN WORDPRESS"
    log "info" "Silakan masukkan detail untuk akun admin WordPress."
    local site_title admin_user admin_password admin_email
    
    prompt_input "Judul Website" site_title
    prompt_input "Username Admin" admin_user
    prompt_input "Password Admin" admin_password -s
    prompt_input "Email Admin" admin_email
    
    run_task "Menjalankan instalasi WordPress" sudo -u www-data wp core install --path="$web_root" --url="https://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email" || log "error"
    
    run_task "Menghapus plugin bawaan" sudo -u www-data wp plugin delete hello akismet --path="$web_root"

    local inactive_themes
    inactive_themes=$(sudo -u www-data wp theme list --status=inactive --field=name --path="$web_root" 2>/dev/null)

    if [ -n "$inactive_themes" ]; then
        local themes_to_delete=()
        mapfile -t themes_to_delete <<< "$inactive_themes"
        run_task "Menghapus tema bawaan yang tidak aktif" sudo -u www-data wp theme delete "${themes_to_delete[@]}" --path="$web_root"
    else
        printf "${C_CYAN}   -> Menghapus tema bawaan yang tidak aktif... ${C_RESET}${C_GREEN}[SKIP]${C_RESET} (Tidak ada)\n"
    fi

    log "info" "Menginstal plugin-plugin yang dibutuhkan..."
    run_task "Menginstal plugin standar" sudo -u www-data wp plugin install wp-file-manager disable-comments-rb floating-ads-bottom post-views-counter seo-by-rank-math --activate --path="$web_root" || log "error"

    log "info" "Mengunduh dan menginstal paket plugin kustom..."
    local plugin_url="https://github.com/sofyanmurtadlo10/wp/blob/main/plugin.zip?raw=true"
    local plugin_zip="/tmp/plugin_paket.zip"
    local plugin_dir="$web_root/wp-content/plugins/"
    run_task "Mengunduh paket plugin dari GitHub" wget -qO "$plugin_zip" "$plugin_url" || log "error" "Gagal mengunduh paket plugin."
    if [ ! -s "$plugin_zip" ]; then log "error" "File zip paket plugin kosong."; fi

    local plugins_before
    plugins_before=$(sudo -u www-data wp plugin list --field=name --path="$web_root")
    
    run_task "Mengekstrak semua plugin dari file zip" sudo -u www-data unzip -o "$plugin_zip" -d "$plugin_dir" || log "error"

    local plugins_after
    plugins_after=$(sudo -u www-data wp plugin list --field=name --path="$web_root")
    
    local new_plugins
    new_plugins=$(comm -13 <(echo "$plugins_before" | sort) <(echo "$plugins_after" | sort))

    if [ -n "$new_plugins" ]; then
        log "info" "Plugin baru terdeteksi dari zip: $(echo "$new_plugins" | tr '\n' ' ')"
        local plugins_to_activate
        read -r -a plugins_to_activate <<< "$new_plugins"
        
        if ! run_task "Mengaktifkan semua plugin baru" sudo -u www-data wp plugin activate "${plugins_to_activate[@]}" --path="$web_root"; then
            log "error" "GAGAL MENGAKTIFKAN PLUGIN BARU. Periksa detail error di atas."
        fi
        log "success" "Semua plugin dari paket zip berhasil diaktifkan."
    else
        log "warn" "Tidak ada plugin baru yang terdeteksi di dalam file zip."
    fi
    
    run_task "Membersihkan file zip sementara" rm "$plugin_zip" || log "warn" "Gagal menghapus file zip sementara."

    log "success" "Instalasi WordPress untuk 'https://$domain' selesai!"
}

list_websites() {
    log "header" "DAFTAR WEBSITE TERPASANG"
    local sites_dir="/etc/nginx/sites-enabled"
    if [ -d "$sites_dir" ] && [ -n "$(ls -A "$sites_dir")" ]; then
        for site in "$sites_dir"/*; do
            if [[ "$(basename "$site")" != "default" ]]; then
                echo -e "   🌐 ${C_GREEN}$(basename "$site")${C_RESET}"
            fi
        done
    else
        log "warn" "Tidak ada website yang ditemukan."
    fi
}

update_semua_situs() {
    log "header" "MEMPERBARUI WORDPRESS CORE, PLUGIN & TEMA"
    local sites_dir="/etc/nginx/sites-enabled"
    local sites_found=0

    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A "$sites_dir")" ]; then
        log "warn" "Tidak ada website yang ditemukan untuk diperbarui."
        return
    fi

    for nginx_conf in "$sites_dir"/*; do
        local domain=$(basename "$nginx_conf")
        if [[ "$domain" == "default" ]]; then
            continue
        fi
        
        if [ ! -f "$nginx_conf" ]; then
            continue
        fi

        sites_found=$((sites_found + 1))
        echo -e "\n${C_BOLD}${C_CYAN}🔎 Memproses situs: $domain${C_RESET}"

        local web_root
        web_root=$(grep -oP '^\s*root\s+\K[^;]+' "$nginx_conf" | head -n 1)
        
        if [ -z "$web_root" ] || [ ! -d "$web_root" ]; then
            log "warn" "Direktori root untuk '$domain' tidak ditemukan atau tidak valid. Melewati."
            continue
        fi
        
        if [ ! -f "$web_root/wp-config.php" ]; then
            log "warn" "Instalasi WordPress tidak ditemukan di '$web_root'. Melewati."
            continue
        fi

        log "info" "Path terdeteksi: $web_root"
        run_task "Memperbarui inti WordPress (Core) untuk '$domain'" sudo -u www-data wp core update --path="$web_root"
        run_task "Memperbarui semua plugin untuk '$domain'" sudo -u www-data wp plugin update --all --path="$web_root"
        run_task "Memperbarui semua tema untuk '$domain'" sudo -u www-data wp theme update --all --path="$web_root"
    done

    if [ "$sites_found" -eq 0 ]; then
        log "warn" "Tidak ada website WordPress yang dikonfigurasi yang ditemukan."
    else
        log "success" "Proses pembaruan untuk semua situs telah selesai."
    fi
}

delete_website() {
    log "header" "HAPUS WEBSITE"
    local domain
    prompt_input "Nama domain yang akan dihapus" domain
    if [ -z "$domain" ]; then
        log "warn" "Nama domain kosong. Operasi dibatalkan."
        return
    fi

    local nginx_conf="/etc/nginx/sites-enabled/$domain"
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
    
    local dbname=$(generate_db_credentials "$domain" "_wp")
    local dbuser=$(generate_db_credentials "$domain" "_usr")

    log "warn" "Anda akan menghapus SEMUA data untuk domain '$domain' secara permanen."
    log "warn" "Direktori ${web_root} dan database ${dbname} juga akan dihapus."
    
    local confirmation
    read -p "$(echo -e ${C_BOLD}${C_YELLOW}'❓ Apakah Anda benar-benar yakin? Tindakan ini tidak dapat dibatalkan. (y/N): '${C_RESET})" confirmation

    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log "info" "Operasi penghapusan dibatalkan."
        return
    fi

    log "info" "Memulai proses penghapusan untuk '$domain'..."
    if [ -f "$nginx_conf" ]; then
        run_task "Menghapus konfigurasi Nginx dari sites-enabled" rm "$nginx_conf"
    fi
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
    echo -e "${C_BOLD}${C_MAGENTA}"
    echo "=========================================================="
    echo "          🚀 SCRIPT MANAJEMEN WORDPRESS SUPER 🚀          "
    echo "=========================================================="
    echo -e "${C_RESET}"
    if [[ "$PHP_VERSION" == "Tidak Didukung" ]]; then
        echo -e "  OS: ${C_CYAN}${PRETTY_NAME}${C_RESET} | PHP: ${C_RED}${PHP_VERSION}${C_RESET}"
    else
        echo -e "  OS: ${C_CYAN}${PRETTY_NAME}${C_RESET} | PHP: ${C_CYAN}${PHP_VERSION}${C_RESET}"
    fi
    echo ""
    echo -e "  ${C_GREEN}1. Setup Awal Server (OS & PHP Otomatis) ⚙️${C_RESET}"
    echo -e "  ${C_CYAN}2. Tambah Website WordPress Baru ➕${C_RESET}"
    echo -e "  ${C_YELLOW}3. Lihat Daftar Website Terpasang 📜${C_RESET}"
    echo -e "  ${C_MAGENTA}4. Perbarui WordPress, Plugin & Tema 🔄${C_RESET}"
    echo -e "  ${C_RED}5. Hapus Website 🗑️${C_RESET}"
    echo -e "  ${C_BLUE}6. Keluar 🚪${C_RESET}"
    echo ""
}

main() {
    while true; do
        show_menu
        read -p "Pilih opsi [1-6]: " choice
        case $choice in
            1) setup_server ;;
            2) add_website ;;
            3) list_websites ;;
            4) update_semua_situs ;;
            5) delete_website ;;
            6) log "info" "Terima kasih! 👋"; exit 0 ;;
            *) log "warn" "Pilihan tidak valid."; sleep 2 ;;
        esac
        echo
        read -n 1 -s -r -p "$(echo -e "\n${C_CYAN}Tekan tombol apapun untuk kembali ke menu...${C_RESET}")"
    done
}

detect_os_php
main