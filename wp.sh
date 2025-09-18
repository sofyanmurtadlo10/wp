#!/bin/bash

C_RESET='\e[0m'
C_RED='\e[1;31m'
C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m'
C_BLUE='\e[1;34m'
C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

print_info() { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
print_success() { echo -e "${C_GREEN}SUKSES:${C_RESET} $1"; }
print_warning() { echo -e "${C_YELLOW}PERINGATAN:${C_RESET} $1"; }
print_error() { echo -e "${C_RED}ERROR:${C_RESET} $1"; }

run_task() {
    local description=$1
    shift
    local command=$@
    
    printf "${C_CYAN}  -> ${description}...${C_RESET}"
    output=$($command 2>&1)
    if [ $? -eq 0 ]; then
        printf " ${C_GREEN}[OK]${C_RESET}\n"
    else
        printf " ${C_RED}[GAGAL]${C_RESET}\n"
        print_error "Detail: $output"
        exit 1
    fi
}

install_dependencies() {
    print_info "Memulai instalasi dependensi dasar & optimasi..."
    
    run_task "Memperbarui daftar paket" "sudo apt-get update -y"
    
    print_info "Menginstal paket-paket inti, optimasi, dan keamanan..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nginx mariadb-server mariadb-client software-properties-common \
        unzip curl wget fail2ban certbot python3-certbot-nginx redis-server
        
    print_info "Menginstal PHP 8.3 dan ekstensi (termasuk Redis)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php8.3-fpm php8.3-mysql php8.3-xml php8.3-curl php8.3-gd \
        php8.3-imagick php8.3-mbstring php8.3-zip php8.3-intl php8.3-bcmath php8.3-redis
    
    print_info "Menginstal WP-CLI (WordPress Command Line Interface)..."
    run_task "Mengunduh WP-CLI" "wget https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /tmp/wp-cli.phar"
    run_task "Membuat WP-CLI executable" "sudo chmod +x /tmp/wp-cli.phar"
    run_task "Memindahkan WP-CLI ke direktori bin" "sudo mv /tmp/wp-cli.phar /usr/local/bin/wp"

    print_info "Konfigurasi Nginx untuk FastCGI Caching..."
    sudo tee "/etc/nginx/fastcgi-cache.conf" > /dev/null <<'EOF'
fastcgi_cache_path /var/run/nginx-cache levels=1:2 keys_zone=WORDPRESS:100m inactive=60m;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_cache_use_stale error timeout invalid_header http_500;
fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
EOF
    run_task "Menambahkan konfigurasi FastCGI ke nginx.conf" "sudo sed -i '/http {/a \ \ \ \ include /etc/nginx/fastcgi-cache.conf;' /etc/nginx/nginx.conf"

    print_info "Mengamankan MariaDB..."
    run_task "Membuat password untuk root MariaDB" "sudo mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY 'mysql_root_pass_ganti_ini';\""
    run_task "Menghapus database tes dan user anonim" "sudo mysql -e \"DROP DATABASE IF EXISTS test; DELETE FROM mysql.user WHERE User='';\""
    run_task "Reload privileges" "sudo mysql -e \"FLUSH PRIVILEGES;\""
    
    print_info "Konfigurasi Firewall (UFW)..."
    run_task "Mengizinkan SSH" "sudo ufw allow 'OpenSSH'"
    run_task "Mengizinkan Nginx (HTTP & HTTPS)" "sudo ufw allow 'Nginx Full'"
    run_task "Mengaktifkan UFW" "sudo ufw --force enable"
    
    print_info "Konfigurasi Fail2Ban..."
    run_task "Membuat file konfigurasi lokal untuk Fail2Ban" "sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local"
    run_task "Mengaktifkan dan memulai layanan Fail2Ban" "sudo systemctl enable --now fail2ban"

    print_success "Semua dependensi dasar dan optimasi berhasil diinstal."
}

install_new_website() {
    print_info "Memulai proses instalasi website WordPress baru yang dioptimasi."
    
    while true; do
        read -p "$(echo -e ${C_YELLOW}'Masukkan nama domain (contoh: domain.com): '${C_RESET})" domain
        [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]] && break || print_error "Format domain tidak valid."
    done

    local dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp
    local dbuser=$(echo "$domain" | tr '.' '_' | cut -c1-16)_usr
    local dbpass=$(openssl rand -base64 12)

    print_info "Detail database yang akan dibuat:"
    echo "  - Nama DB  : $dbname"
    echo "  - User DB  : $dbuser"
    echo "  - Password : $dbpass (Simpan password ini!)"
    
    print_info "Menyiapkan database..."
    run_task "Membuat database '$dbname'" "sudo mysql -e \"CREATE DATABASE $dbname;\""
    run_task "Membuat user '$dbuser'" "sudo mysql -e \"CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$dbpass';\""
    run_task "Memberikan hak akses" "sudo mysql -e \"GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;\""

    local web_root="/var/www/$domain"
    print_info "Mengunduh dan mengonfigurasi WordPress menggunakan WP-CLI..."
    run_task "Membuat direktori root" "sudo mkdir -p $web_root"
    run_task "Mengubah kepemilikan direktori ke www-data" "sudo chown -R www-data:www-data $web_root"
    run_task "Mengunduh file WordPress sebagai user www-data" "sudo -u www-data wp core download --path=$web_root"
    run_task "Membuat file wp-config.php" "sudo -u www-data wp config create --path=$web_root --dbname=$dbname --dbuser=$dbuser --dbpass=$dbpass --extra-php <<PHP
define('WP_CACHE', true);
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
PHP"
    
    print_info "Membuat file konfigurasi Nginx Performa Tinggi untuk '$domain'..."
    sudo tee "/etc/nginx/sites-available/$domain" > /dev/null <<EOF
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain www.$domain;
    root $web_root;
    index index.php;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    client_max_body_size 100M;

    # Aturan FastCGI Caching
    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|index.php|sitemap(_index)?.xml") { set \$skip_cache 1; }
    if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") { set \$skip_cache 1; }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        
        # Konfigurasi Caching
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 60m;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        add_header X-Cache-Status \$upstream_cache_status;
    }
    
    # Blokir akses ke file sensitif
    location ~* /(?:uploads|files)/.*\.php$ { deny all; }
    location ~* /wp-config.php|/wp-includes/|/\.git|/\.svn { deny all; }
}
EOF
    run_task "Mengaktifkan site Nginx" "sudo ln -s /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/"
    
    print_info "Mengatur izin file yang benar..."
    run_task "Mengatur izin direktori" "sudo find $web_root -type d -exec chmod 755 {} \;"
    run_task "Mengatur izin file" "sudo find $web_root -type f -exec chmod 644 {} \;"

    print_info "Menjalankan Certbot untuk mendapatkan sertifikat SSL..."
    run_task "Menguji konfigurasi Nginx" "sudo nginx -t"
    run_task "Reload Nginx" "sudo systemctl reload nginx"
    sudo certbot --nginx --agree-tos --redirect --hsts --staple-ocsp --email admin@$domain -d $domain,www.$domain
    
    print_info "Menyelesaikan Instalasi WordPress & Menginstal Plugin Cache..."
    read -p "$(echo -e ${C_YELLOW}'Judul Website: '${C_RESET})" site_title
    read -p "$(echo -e ${C_YELLOW}'Username Admin: '${C_RESET})" admin_user
    read -s -p "$(echo -e ${C_YELLOW}'Password Admin: '${C_RESET})" admin_password; echo
    read -p "$(echo -e ${C_YELLOW}'Email Admin: '${C_RESET})" admin_email
    
    run_task "Menjalankan instalasi WordPress inti" "sudo -u www-data wp core install --path=$web_root --url=https://$domain --title=\"$site_title\" --admin_user=$admin_user --admin_password=$admin_password --admin_email=$admin_email"
    run_task "Menginstal plugin Redis Object Cache" "sudo -u www-data wp plugin install redis-cache --activate --path=$web_root"
    run_task "Mengaktifkan Redis Object Cache" "sudo -u www-data wp redis enable --path=$web_root"
    
    print_success "Instalasi WordPress super cepat untuk 'https://$domain' selesai!"
    print_warning "Jangan lupa untuk menyimpan password database DAN admin yang ditampilkan di atas."
}

list_websites() {
    print_info "Mencari website yang dikelola oleh Nginx..."
    local sites_dir="/etc/nginx/sites-enabled"
    
    if [ -d "$sites_dir" ] && [ "$(ls -A $sites_dir)" ]; then
        echo -e "${C_BOLD}---------------------------------------------${C_RESET}"
        for site in $(ls $sites_dir); do
            if [ "$site" != "default" ]; then
                echo -e "  - ${C_GREEN}$site${C_RESET} (https://$site)"
            fi
        done
        echo -e "${C_BOLD}---------------------------------------------${C_RESET}"
    else
        print_warning "Tidak ada website yang ditemukan."
    fi
}

show_menu() {
    clear
    echo -e "${C_CYAN}"
    echo "=========================================================="
    echo "  🚀 SCRIPT INSTALASI WORDPRESS - PERFORMA & KEAMANAN 🚀  "
    echo "=========================================================="
    echo -e "${C_RESET}"
    echo -e "  ${C_GREEN}1. Setup Server (Instalasi Dependensi & Optimasi)${C_RESET}"
    echo -e "  ${C_BLUE}2. Install Website WordPress Baru (Cepat & Aman)${C_RESET}"
    echo -e "  ${C_YELLOW}3. Lihat Daftar Website Terinstall${C_RESET}"
    echo -e "  ${C_RED}4. Keluar${C_RESET}"
    echo ""
}

while true; do
    show_menu
    read -p "$(echo -e ${C_BOLD}'Pilih opsi [1-4]: '${C_RESET})" choice
    case $choice in
        1)
            install_dependencies
            read -n 1 -s -r -p "Tekan tombol apapun untuk kembali ke menu..."
            ;;
        2)
            install_new_website
            read -n 1 -s -r -p "Tekan tombol apapun untuk kembali ke menu..."
            ;;
        3)
            list_websites
            read -n 1 -s -r -p "Tekan tombol apapun untuk kembali ke menu..."
            ;;
        4)
            echo -e "\n${C_BOLD}Terima kasih telah menggunakan skrip ini!${C_RESET}"
            exit 0
            ;;
        *)
            print_error "Pilihan tidak valid. Silakan coba lagi."
            sleep 2
            ;;
    esac
done