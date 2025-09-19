#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
   echo "❌ Kesalahan: Skrip ini harus dijalankan sebagai root. Coba 'sudo bash $0'" 
   exit 1
fi

C_RESET='\e[0m'
C_RED='\e[1;31m'    C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m' C_BLUE='\e[1;34m'
C_MAGENTA='\e[1;35m' C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

readonly password_file="mariadb_root_pass.txt"
declare -g mariadb_unified_pass

log() {
  local type=$1
  local msg=$2
  case "$type" in
    "info")    echo -e "${C_BLUE}INFO:${C_RESET} $msg" ;;
    "success") echo -e "${C_GREEN}SUKSES:${C_RESET} $msg" ;;
    "warn")    echo -e "${C_YELLOW}PERINGATAN:${C_RESET} $msg" ;;
    "error")   echo -e "${C_RED}ERROR:${C_RESET} $msg${C_RESET}"; exit 1 ;;
    "header")  echo -e "\n${C_BOLD}${C_MAGENTA}--- $msg ---${C_RESET}" ;;
  esac
}

run_task() {
  local description=$1
  shift
  local command_args=("$@")
  
  printf "${C_CYAN}  -> %s... ${C_RESET}" "$description"
  
  output=$("${command_args[@]}" 2>&1)
  
  if [[ $? -eq 0 ]]; then
    echo -e "${C_GREEN}[OK]${C_RESET}"
    return 0
  else
    echo -e "${C_RED}[GAGAL]${C_RESET}"
    echo -e "${C_RED}==================== DETAIL ERROR ====================${C_RESET}" >&2
    echo -e "$output" >&2
    echo -e "${C_RED}====================================================${C_RESET}" >&2
    log "error" "Gagal menjalankan '$description'. Silakan periksa detail error di atas."
  fi
}

load_or_create_password() {
  if [ -s "$password_file" ]; then
    mariadb_unified_pass=$(cat "$password_file")
    log "info" "Kata sandi MariaDB berhasil dimuat dari '$password_file'."
  else
    log "header" "KONFIGURASI KATA SANDI MARIADB"
    echo -e "${C_YELLOW}Anda perlu membuat kata sandi 'root' untuk MariaDB.${C_RESET}"
    echo -e "${C_YELLOW}Kata sandi ini akan disimpan di '$password_file' agar tidak perlu memasukkannya lagi.${C_RESET}"
    read -s -p "Masukkan kata sandi baru untuk MariaDB root: " mariadb_unified_pass; echo
    
    if [ -z "$mariadb_unified_pass" ]; then
      log "error" "Kata sandi tidak boleh kosong."
    fi
    
    echo "$mariadb_unified_pass" > "$password_file"
    chmod 600 "$password_file"
    log "success" "Kata sandi berhasil disimpan ke '$password_file'. Pastikan file ini aman."
  fi
}

setup_server() {
  log "header" "MEMULAI SETUP SERVER"
  log "info" "Memeriksa dan menginstal dependensi yang dibutuhkan..."

  run_task "Memperbarui daftar paket" apt-get update -y

  if ! dpkg -s software-properties-common &> /dev/null; then
      run_task "Menginstal software-properties-common" apt-get install -y software-properties-common
  else
      log "info" "Paket software-properties-common sudah terinstal."
  fi

  if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
      log "info" "Menambahkan PPA PHP 8.3 dari Ondrej Sury..."
      run_task "Menambahkan PPA ondrej/php" add-apt-repository -y ppa:ondrej/php
      run_task "Memperbarui daftar paket lagi setelah menambah PPA" apt-get update -y
  else
      log "info" "PPA ondrej/php sudah ada."
  fi
  
  local packages_needed=(
    nginx mariadb-server mariadb-client unzip curl wget fail2ban redis-server 
    php8.3-fpm php8.3-mysql php8.3-xml php8.3-curl php8.3-gd php8.3-imagick 
    php8.3-mbstring php8.3-zip php8.3-intl php8.3-bcmath php8.3-redis
  )
  local packages_to_install=()
  for pkg in "${packages_needed[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
      packages_to_install+=("$pkg")
    fi
  done

  if [ ${#packages_to_install[@]} -gt 0 ]; then
    log "info" "Menginstal paket inti yang belum ada..."
    run_task "Menginstal paket: ${packages_to_install[*]}" apt-get install -y "${packages_to_install[@]}"
  else
    log "info" "Semua paket inti sudah terinstal."
  fi

  if ! command -v wp &> /dev/null; then
    log "info" "Menginstal WP-CLI..."
    run_task "Mengunduh WP-CLI phar" wget -nv https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /usr/local/bin/wp
    run_task "Memberikan izin eksekusi pada WP-CLI" chmod +x /usr/local/bin/wp
  else
    log "info" "WP-CLI sudah terinstal."
  fi

  log "info" "Mengonfigurasi MariaDB..."
  if ! systemctl is-active --quiet mariadb; then
    run_task "Mengaktifkan & memulai layanan MariaDB" systemctl enable --now mariadb.service
  fi
  load_or_create_password
  mysql -u root -p"$mariadb_unified_pass" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_unified_pass';"
  
  log "info" "Mengonfigurasi Nginx FastCGI Caching..."
  if [ ! -f "/etc/nginx/conf.d/fastcgi_cache.conf" ]; then
    tee /etc/nginx/conf.d/fastcgi_cache.conf > /dev/null <<'EOF'
fastcgi_cache_path /var/run/nginx-cache levels=1:2 keys_zone=WORDPRESS:100m inactive=60m;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
EOF
    run_task "Memeriksa konfigurasi Nginx setelah menambah cache" nginx -t
  else
    log "info" "Konfigurasi FastCGI Cache sudah ada."
  fi

  log "info" "Mengonfigurasi Firewall (UFW)..."
  if ! ufw status | grep -q "Status: active"; then
    run_task "Mengizinkan koneksi SSH" ufw allow 'OpenSSH'
    run_task "Mengizinkan koneksi Nginx" ufw allow 'Nginx Full'
    run_task "Mengaktifkan UFW" ufw --force enable
  else
    log "info" "UFW sudah aktif."
  fi
  
  log "success" "Setup server selesai! Semua dependensi sudah siap."
}

add_website() {
  log "header" "TAMBAH WEBSITE WORDPRESS BARU"

  if ! command -v wp &> /dev/null; then
      log "error" "WP-CLI tidak ditemukan. Jalankan 'Setup Server' terlebih dahulu."
  fi
  
  load_or_create_password

  local domain dbname dbuser web_root site_title admin_user admin_password admin_email

  while true; do
    read -p "Masukkan nama domain (contoh: domainanda.com): " domain
    if [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      log "warn" "Format domain tidak valid. Mohon coba lagi."
    fi
  done
  
  web_root="/var/www/$domain/public_html"
  dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp
  dbuser=$(echo "$domain" | tr '.' '_' | cut -c1-16)_usr

  log "info" "Memeriksa konflik untuk domain '$domain'..."
  if [ -d "/var/www/$domain" ]; then
    log "error" "Direktori '/var/www/$domain' sudah ada. Hapus dulu jika ingin melanjutkan."
  fi
  if [ -f "/etc/nginx/sites-available/$domain" ]; then
    log "error" "File konfigurasi Nginx untuk '$domain' sudah ada. Hapus dulu jika ingin melanjutkan."
  fi
  if mysql -u root -p"$mariadb_unified_pass" -e "USE $dbname;" &>/dev/null; then
    log "error" "Database '$dbname' sudah ada. Hapus dulu jika ingin melanjutkan."
  fi
  log "success" "Tidak ada konflik ditemukan. Melanjutkan instalasi."

  log "info" "Membuat database dan user untuk '$domain'..."
  run_task "Membuat database '$dbname'" mysql -u root -p"$mariadb_unified_pass" -e "CREATE DATABASE $dbname;"
  run_task "Membuat user '$dbuser'" mysql -u root -p"$mariadb_unified_pass" -e "CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$mariadb_unified_pass';"
  run_task "Memberikan hak akses ke database" mysql -u root -p"$mariadb_unified_pass" -e "GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;"
  
  log "info" "Mengunduh & mengonfigurasi WordPress..."
  run_task "Membuat direktori root '$web_root'" mkdir -p "$web_root"
  run_task "Mengubah kepemilikan direktori ke www-data" chown -R www-data:www-data "/var/www/$domain"
  
  run_task "Mengunduh file inti WordPress" sudo -u www-data wp core download --path="$web_root"
  run_task "Membuat file wp-config.php" sudo -u www-data wp config create --path="$web_root" \
    --dbname="$dbname" --dbuser="$dbuser" --dbpass="$mariadb_unified_pass" --extra-php <<'PHP'
define('WP_CACHE', true);
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
PHP

  log "header" "KONFIGURASI SSL (HTTPS)"
  echo "Anda perlu menempelkan konten sertifikat SSL dan kunci privat."
  read -p "Tekan ENTER untuk melanjutkan ke editor teks (nano)..."
  
  local ssl_dir="/etc/nginx/ssl/$domain"
  run_task "Membuat direktori SSL" mkdir -p "$ssl_dir"
  local ssl_cert_path="$ssl_dir/$domain.crt"
  local ssl_key_path="$ssl_dir/$domain.key"
  
  echo -e "${C_YELLOW}Tempelkan konten sertifikat (.crt), lalu simpan (Ctrl+X, Y, Enter).${C_RESET}"
  read -p "Tekan ENTER untuk membuka editor sertifikat..."
  nano "$ssl_cert_path"

  echo -e "${C_YELLOW}Tempelkan konten Kunci Privat (.key), lalu simpan (Ctrl+X, Y, Enter).${C_RESET}"
  read -p "Tekan ENTER untuk membuka editor kunci privat..."
  nano "$ssl_key_path"

  if [ ! -s "$ssl_cert_path" ] || [ ! -s "$ssl_key_path" ]; then
    log "error" "File sertifikat atau kunci privat kosong. Instalasi dibatalkan."
  fi

  log "info" "Membuat file konfigurasi Nginx untuk '$domain'..."
  tee "/etc/nginx/sites-available/$domain" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain www.$domain;
    root $web_root;
    index index.php;

    # Aturan untuk Rank Math SEO
    rewrite ^/sitemap_index\.xml$ /index.php?sitemap=1 last;
    rewrite ^/([^/]+?)-sitemap([0-9]+)?\.xml$ /index.php?sitemap=$1&sitemap_n=$2 last;
    rewrite ^/sitemap\.xsl$ /index.php?sitemap_xsl=1 last;

    ssl_certificate $ssl_cert_path;
    ssl_certificate_key $ssl_key_path;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM";
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    client_max_body_size 100M;
    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|sitemap(_index)?.xml") { set \$skip_cache 1; }
    if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") { set \$skip_cache 1; }
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 60m;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        add_header X-Cache-Status \$upstream_cache_status;
    }
    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF

  run_task "Mengaktifkan site Nginx" ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/"
  
  log "info" "Menyelesaikan konfigurasi..."
  run_task "Menguji konfigurasi Nginx" nginx -t
  run_task "Me-reload layanan Nginx" systemctl reload nginx
  
  log "header" "INFORMASI ADMIN WORDPRESS"
  read -p "Masukkan Judul Website: " site_title
  read -p "Masukkan Username Admin: " admin_user
  read -s -p "Masukkan Password Admin: " admin_password; echo
  read -p "Masukkan Email Admin: " admin_email
  
  run_task "Menjalankan instalasi inti WordPress" sudo -u www-data wp core install --path="$web_root" --url="https://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email"
  
  log "info" "Menginstal dan mengaktifkan plugin-plugin yang dibutuhkan..."
  run_task "Menginstal plugin" sudo -u www-data wp plugin install \
    redis-cache \
    wp-file-manager \
    disable-comments-rb \
    floating-ads-bottom \
    post-views-counter \
    seo-by-rank-math \
    --activate --path="$web_root"

  run_task "Mengaktifkan Redis Object Cache" sudo -u www-data wp redis enable --path="$web_root"
  
  echo -e "${C_GREEN}=======================================================${C_RESET}"
  log "success" "Instalasi WordPress untuk 'https://$domain' selesai! 🎉"
  echo -e "${C_BOLD}URL Login:      ${C_CYAN}https://$domain/wp-admin/${C_RESET}"
  echo -e "${C_BOLD}Username:       ${C_CYAN}$admin_user${C_RESET}"
  echo -e "${C_BOLD}Password:       ${C_YELLOW}(Yang baru saja Anda masukkan)${C_RESET}"
  echo -e "-------------------------------------------------------"
  echo -e "${C_BOLD}Database Name:  ${C_CYAN}$dbname${C_RESET}"
  echo -e "${C_BOLD}Database User:  ${C_CYAN}$dbuser${C_RESET}"
  echo -e "${C_GREEN}=======================================================${C_RESET}"
  log "warn" "Pastikan Anda telah mengarahkan DNS domain Anda ke IP server ini."
}

list_websites() {
  log "header" "DAFTAR WEBSITE TERPASANG"
  local sites_dir="/etc/nginx/sites-enabled"
  if [ -d "$sites_dir" ] && [ "$(ls -A $sites_dir)" ]; then
    echo -e "${C_BOLD}Website yang ditemukan di konfigurasi Nginx:${C_RESET}"
    for site in $(ls -A $sites_dir); do
      if [ "$site" != "default" ]; then
        echo -e "  🌐 ${C_GREEN}$site${C_RESET} (https://$site)"
      fi
    done
  else
    log "warn" "Tidak ada website yang ditemukan."
  fi
}

delete_website() {
  log "header" "HAPUS WEBSITE"
  read -p "Masukkan nama domain yang ingin dihapus (contoh: domainanda.com): " domain
  
  if [ -z "$domain" ]; then
    log "warn" "Nama domain tidak boleh kosong. Operasi dibatalkan."
    return
  fi

  local web_root="/var/www/$domain"
  local nginx_conf="/etc/nginx/sites-available/$domain"
  local nginx_symlink="/etc/nginx/sites-enabled/$domain"
  local ssl_dir="/etc/nginx/ssl/$domain"
  local dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp
  local dbuser=$(echo "$domain" | tr '.' '_' | cut -c1-16)_usr

  log "warn" "Anda akan menghapus semua data untuk domain '$domain'."
  log "warn" "Ini termasuk file web, database, konfigurasi Nginx, dan sertifikat SSL."
  
  echo ""
  echo -e "${C_YELLOW}*** PERINGATAN PENTING ***${C_RESET}"
  echo "Operasi ini akan MENGHAPUS SEMUA DATA secara permanen."
  echo "Tindakan ini TIDAK BISA DIURUNGKAN."
  read -p "Untuk konfirmasi, ketik nama domain '$domain' lalu tekan Enter: " confirmation

  if [ "$confirmation" != "$domain" ]; then
    log "info" "Konfirmasi tidak cocok. Operasi penghapusan dibatalkan."
    return
  fi

  log "info" "Memulai proses penghapusan untuk '$domain'..."
  
  if [ -L "$nginx_symlink" ]; then run_task "Menghapus symlink Nginx" rm "$nginx_symlink"; fi
  if [ -f "$nginx_conf" ]; then run_task "Menghapus konfigurasi Nginx" rm "$nginx_conf"; fi
  run_task "Me-reload Nginx" systemctl reload nginx
  if [ -d "$web_root" ]; then run_task "Menghapus direktori web" rm -rf "$web_root"; fi
  if [ -d "$ssl_dir" ]; then run_task "Menghapus direktori SSL" rm -rf "$ssl_dir"; fi

  load_or_create_password
  if mysql -u root -p"$mariadb_unified_pass" -e "USE $dbname;" &>/dev/null; then
    run_task "Menghapus database '$dbname'" mysql -u root -p"$mariadb_unified_pass" -e "DROP DATABASE $dbname;"
    run_task "Menghapus user database '$dbuser'" mysql -u root -p"$mariadb_unified_pass" -e "DROP USER '$dbuser'@'localhost';"
    run_task "Memuat ulang hak akses" mysql -u root -p"$mariadb_unified_pass" -e "FLUSH PRIVILEGES;"
  fi

  log "success" "Semua data untuk domain '$domain' telah berhasil dihapus."
}

show_menu() {
  clear
  echo -e "${C_BOLD}${C_MAGENTA}"
  echo "=========================================================="
  echo "         🚀 SCRIPT MANAJEMEN WORDPRESS SUPER 🚀       "
  echo "=========================================================="
  echo -e "${C_RESET}"
  echo -e "  ${C_GREEN}1. Setup Server Awal (Hanya sekali jalan) ⚙️${C_RESET}"
  echo -e "  ${C_CYAN}2. Tambah Website WordPress Baru ➕${C_RESET}"
  echo -e "  ${C_YELLOW}3. Lihat Daftar Website Terpasang 📜${C_RESET}"
  echo -e "  ${C_RED}4. Hapus Website 🗑️${C_RESET}"
  echo -e "  ${C_BLUE}5. Keluar 🚪${C_RESET}"
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
      5)
        log "info" "Terima kasih telah menggunakan skrip ini! 👋"
        exit 0
        ;;
      *)
        log "warn" "Pilihan tidak valid. Silakan coba lagi."
        sleep 2
        ;;
    esac
    echo
    read -n 1 -s -r -p "Tekan tombol apapun untuk kembali ke menu..."
  done
}

main