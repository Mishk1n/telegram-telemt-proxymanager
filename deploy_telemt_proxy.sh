#!/bin/bash

# ============================================
# TeleMT Proxy Auto-Installer
# MTProto прокси для Telegram на Rust
# Режимы: classic (обычный), dd (secure), ee (FakeTLS)
# Поддержка нескольких контейнеров
# ============================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Глобальные переменные
EXISTING_CLASSIC=false
EXISTING_DD=false
EXISTING_EE=false
REINSTALL=false
PROXY_MODE=""
BASE_DIR=""
CONTAINER_NAME=""
PORT=""
SECRET=""
SECRET_BASE=""
TLS_DOMAIN=""
PUBLIC_IP=""

# Функции вывода
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo ""
    echo "========================================="
    echo -e "${GREEN}$1${NC}"
    echo "========================================="
}

# Проверка root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Запустите с sudo: sudo $0"
        exit 1
    fi
}

# Установка минимальных зависимостей
install_deps() {
    print_info "Проверка наличия необходимых утилит..."
    
    apt update
    
    for pkg in curl openssl xxd iproute2; do
        if ! command -v $pkg &>/dev/null; then
            print_info "Установка $pkg..."
            apt install -y $pkg
        fi
    done
    
    print_success "Необходимые утилиты установлены"
}

# Проверка существующих контейнеров
check_existing_containers() {
    EXISTING_CLASSIC=false
    EXISTING_DD=false
    EXISTING_EE=false
    
    # Проверяем через docker
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^telemt-classic$"; then
        EXISTING_CLASSIC=true
        print_info "Обнаружен существующий контейнер telemt-classic"
    fi
    
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^telemt-dd$"; then
        EXISTING_DD=true
        print_info "Обнаружен существующий контейнер telemt-dd"
    fi
    
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^telemt-ee$"; then
        EXISTING_EE=true
        print_info "Обнаружен существующий контейнер telemt-ee"
    fi
    
    # Также проверяем директории
    [ -d "/opt/telemt-classic" ] && EXISTING_CLASSIC=true
    [ -d "/opt/telemt-dd" ] && EXISTING_DD=true
    [ -d "/opt/telemt-ee" ] && EXISTING_EE=true
}

# Выбор режима с учетом существующих
select_mode() {
    print_header "Выбор режима работы прокси"
    
    # Подсчитываем количество установленных режимов
    INSTALLED_COUNT=0
    [ "$EXISTING_CLASSIC" = true ] && INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    [ "$EXISTING_DD" = true ] && INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    [ "$EXISTING_EE" = true ] && INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    
    # Если все три режима уже есть
    if [ $INSTALLED_COUNT -eq 3 ]; then
        echo "⚠️  Все три режима уже установлены!"
        echo ""
        echo "Доступные действия:"
        echo "  1) Переустановить CLASSIC режим (обычный, без шифрования)"
        echo "  2) Переустановить DD режим (secure, с шифрованием)"
        echo "  3) Переустановить EE режим (FakeTLS)"
        echo "  4) Показать ссылки для подключения"
        echo "  5) Выйти"
        echo ""
        read -p "Ваш выбор [5]: " action
        action=${action:-5}
        
        case $action in
            1) PROXY_MODE="classic"; REINSTALL=true ;;
            2) PROXY_MODE="dd"; REINSTALL=true ;;
            3) PROXY_MODE="ee"; REINSTALL=true ;;
            4) show_existing_links; exit 0 ;;
            *) exit 0 ;;
        esac
    else
        # Показываем доступные режимы для установки
        echo "Доступные режимы:"
        echo ""
        
        if [ "$EXISTING_CLASSIC" = false ]; then
            echo "  1) CLASSIC - Обычный MTProto (без шифрования, уязвим к DPI)"
        else
            echo "  ✅ CLASSIC - уже установлен"
        fi
        
        if [ "$EXISTING_DD" = false ]; then
            echo "  2) DD - Secure MTProto (с шифрованием, рекомендуемый)"
        else
            echo "  ✅ DD - уже установлен"
        fi
        
        if [ "$EXISTING_EE" = false ]; then
            echo "  3) EE - FakeTLS (маскировка под HTTPS, лучший для обхода DPI)"
        else
            echo "  ✅ EE - уже установлен"
        fi
        
        echo ""
        
        if [ $INSTALLED_COUNT -eq 2 ]; then
            echo "⚠️  Остался один режим для установки"
            # Автоматически выбираем недостающий режим
            if [ "$EXISTING_CLASSIC" = false ]; then
                PROXY_MODE="classic"
                REINSTALL=false
                print_info "Автоматически выбран режим CLASSIC"
            elif [ "$EXISTING_DD" = false ]; then
                PROXY_MODE="dd"
                REINSTALL=false
                print_info "Автоматически выбран режим DD"
            else
                PROXY_MODE="ee"
                REINSTALL=false
                print_info "Автоматически выбран режим EE"
            fi
        else
            read -p "Выберите режим для установки [1-3]: " mode_choice
            
            case $mode_choice in
                1)
                    if [ "$EXISTING_CLASSIC" = true ]; then
                        read -p "Режим CLASSIC уже установлен. Переустановить? (y/n) [n]: " reinstall_choice
                        if [[ "$reinstall_choice" =~ ^[Yy]$ ]]; then
                            PROXY_MODE="classic"
                            REINSTALL=true
                        else
                            select_mode
                            return
                        fi
                    else
                        PROXY_MODE="classic"
                        REINSTALL=false
                    fi
                    ;;
                2)
                    if [ "$EXISTING_DD" = true ]; then
                        read -p "Режим DD уже установлен. Переустановить? (y/n) [n]: " reinstall_choice
                        if [[ "$reinstall_choice" =~ ^[Yy]$ ]]; then
                            PROXY_MODE="dd"
                            REINSTALL=true
                        else
                            select_mode
                            return
                        fi
                    else
                        PROXY_MODE="dd"
                        REINSTALL=false
                    fi
                    ;;
                3)
                    if [ "$EXISTING_EE" = true ]; then
                        read -p "Режим EE уже установлен. Переустановить? (y/n) [n]: " reinstall_choice
                        if [[ "$reinstall_choice" =~ ^[Yy]$ ]]; then
                            PROXY_MODE="ee"
                            REINSTALL=true
                        else
                            select_mode
                            return
                        fi
                    else
                        PROXY_MODE="ee"
                        REINSTALL=false
                    fi
                    ;;
                *)
                    print_error "Неверный выбор"
                    select_mode
                    return
                    ;;
            esac
        fi
    fi
    
    # Устанавливаем переменные в зависимости от режима
    case $PROXY_MODE in
        classic)
            BASE_DIR="/opt/telemt-classic"
            CONTAINER_NAME="telemt-classic"
            print_success "Выбран режим: CLASSIC (обычный MTProto, без шифрования)"
            ;;
        dd)
            BASE_DIR="/opt/telemt-dd"
            CONTAINER_NAME="telemt-dd"
            print_success "Выбран режим: DD (Secure MTProto, с шифрованием)"
            ;;
        ee)
            BASE_DIR="/opt/telemt-ee"
            CONTAINER_NAME="telemt-ee"
            print_success "Выбран режим: EE (FakeTLS, маскировка под HTTPS)"
            ;;
    esac
}

# Показать существующие ссылки
show_existing_links() {
    print_header "Существующие прокси"
    get_public_ip
    
    if [ "$EXISTING_CLASSIC" = true ] && [ -f /opt/telemt-classic/secret.txt ]; then
        CLASSIC_PORT=$(grep -oP 'port = \K\d+' /opt/telemt-classic/config/telemt.toml 2>/dev/null || echo "8443")
        CLASSIC_SECRET=$(cat /opt/telemt-classic/secret.txt 2>/dev/null)
        echo ""
        echo "📱 РЕЖИМ CLASSIC (обычный, без шифрования):"
        echo -e "${GREEN}tg://proxy?server=${PUBLIC_IP}&port=${CLASSIC_PORT}&secret=${CLASSIC_SECRET}${NC}"
    fi
    
    if [ "$EXISTING_DD" = true ] && [ -f /opt/telemt-dd/secret.txt ]; then
        DD_PORT=$(grep -oP 'port = \K\d+' /opt/telemt-dd/config/telemt.toml 2>/dev/null || echo "8444")
        DD_SECRET=$(cat /opt/telemt-dd/secret.txt 2>/dev/null)
        echo ""
        echo "📱 РЕЖИМ DD (secure, с шифрованием):"
        echo -e "${MAGENTA}tg://proxy?server=${PUBLIC_IP}&port=${DD_PORT}&secret=${DD_SECRET}${NC}"
    fi
    
    if [ "$EXISTING_EE" = true ] && [ -f /opt/telemt-ee/secret.txt ]; then
        EE_PORT=$(grep -oP 'port = \K\d+' /opt/telemt-ee/config/telemt.toml 2>/dev/null || echo "8445")
        EE_SECRET=$(cat /opt/telemt-ee/secret.txt 2>/dev/null)
        echo ""
        echo "📱 РЕЖИМ EE (FakeTLS):"
        echo -e "${YELLOW}tg://proxy?server=${PUBLIC_IP}&port=${EE_PORT}&secret=${EE_SECRET}${NC}"
    fi
    echo ""
}

# Запрос параметров
get_config() {
    print_header "Настройка прокси (режим: $PROXY_MODE)"
    
    # Определяем порт по умолчанию
    DEFAULT_PORT=8443
    
    # Проверяем занятые порты
    USED_PORTS=()
    [ -f /opt/telemt-classic/config/telemt.toml ] && USED_PORTS+=($(grep -oP 'port = \K\d+' /opt/telemt-classic/config/telemt.toml 2>/dev/null))
    [ -f /opt/telemt-dd/config/telemt.toml ] && USED_PORTS+=($(grep -oP 'port = \K\d+' /opt/telemt-dd/config/telemt.toml 2>/dev/null))
    [ -f /opt/telemt-ee/config/telemt.toml ] && USED_PORTS+=($(grep -oP 'port = \K\d+' /opt/telemt-ee/config/telemt.toml 2>/dev/null))
    
    # Находим свободный порт
    while true; do
        if [ ${#USED_PORTS[@]} -gt 0 ]; then
            # Сортируем порты и находим следующий свободный
            SORTED_PORTS=($(printf '%s\n' "${USED_PORTS[@]}" | sort -n))
            DEFAULT_PORT=$((SORTED_PORTS[-1] + 1))
        fi
        
        # Устанавливаем стандартные порты для новых установок
        if [ ${#USED_PORTS[@]} -eq 0 ]; then
            case $PROXY_MODE in
                classic) DEFAULT_PORT=8443 ;;
                dd) DEFAULT_PORT=8444 ;;
                ee) DEFAULT_PORT=8445 ;;
            esac
        fi
        
        read -p "Введите порт для прокси [$DEFAULT_PORT]: " PORT
        PORT=${PORT:-$DEFAULT_PORT}
        
        # Проверяем, не занят ли порт
        if ss -tuln 2>/dev/null | grep -q ":$PORT "; then
            print_warning "Порт $PORT уже занят! Выберите другой порт."
            continue
        fi
        
        # Проверяем конфликты с другими контейнерами
        if [[ " ${USED_PORTS[@]} " =~ " ${PORT} " ]]; then
            print_warning "Порт $PORT уже используется другим прокси!"
            continue
        fi
        
        break
    done
    
    # Для EE режима запрашиваем домен
    if [ "$PROXY_MODE" == "ee" ]; then
        echo ""
        echo "Домены для маскировки трафика:"
        echo "  - rutube.ru"
        echo "  - google.com"
        echo "  - cloudflare.com"
        echo "  - wikipedia.org"
        echo "  - yandex.ru"
        echo ""
        read -p "Введите домен для TLS маскировки [rutube.ru]: " TLS_DOMAIN
        TLS_DOMAIN=${TLS_DOMAIN:-rutube.ru}
    fi
    
    get_secret
}

# Запрос секрета
get_secret() {
    print_header "Настройка секрета прокси"
    
    if [ "$PROXY_MODE" == "classic" ]; then
        echo "Режим CLASSIC: секрет - 32 шестнадцатеричных символа"
        echo "Пример: $(openssl rand -hex 16)"
        echo ""
        echo "⚠️  ВНИМАНИЕ: CLASSIC режим не имеет шифрования и уязвим для DPI"
        echo ""
        
        if [ "$REINSTALL" = true ] && [ -f "$BASE_DIR/secret.txt" ]; then
            read -p "Использовать старый секрет? (y/n) [y]: " use_old
            if [[ "$use_old" =~ ^[Yy]$ ]] || [ -z "$use_old" ]; then
                SECRET=$(cat "$BASE_DIR/secret.txt")
                print_success "Использую существующий секрет"
                return
            fi
        fi
        
        read -p "Введите секрет (или Enter для генерации): " SECRET
        if [ -z "$SECRET" ]; then
            SECRET=$(openssl rand -hex 16)
            print_success "Сгенерирован секрет: $SECRET"
        elif [[ ! $SECRET =~ ^[a-fA-F0-9]{32}$ ]]; then
            print_error "Ошибка: секрет должен содержать 32 hex символа"
            exit 1
        fi
    elif [ "$PROXY_MODE" == "dd" ]; then
        echo "Режим DD (secure): секрет - 32 шестнадцатеричных символа"
        echo "Пример: $(openssl rand -hex 16)"
        echo ""
        echo "✅ Этот режим использует шифрование и более защищен"
        echo ""
        
        if [ "$REINSTALL" = true ] && [ -f "$BASE_DIR/secret.txt" ]; then
            read -p "Использовать старый секрет? (y/n) [y]: " use_old
            if [[ "$use_old" =~ ^[Yy]$ ]] || [ -z "$use_old" ]; then
                SECRET=$(cat "$BASE_DIR/secret.txt")
                print_success "Использую существующий секрет"
                return
            fi
        fi
        
        read -p "Введите секрет (или Enter для генерации): " SECRET
        if [ -z "$SECRET" ]; then
            SECRET=$(openssl rand -hex 16)
            print_success "Сгенерирован секрет: $SECRET"
        elif [[ ! $SECRET =~ ^[a-fA-F0-9]{32}$ ]]; then
            print_error "Ошибка: секрет должен содержать 32 hex символа"
            exit 1
        fi
    else
        echo "Режим EE: секрет = 'ee' + 32 hex символа + hex домена"
        echo "Пример для rutube.ru: ee$(openssl rand -hex 16)$(echo -n 'rutube.ru' | xxd -p)"
        echo ""
        echo "✅ Лучший режим для обхода блокировок"
        echo ""
        
        if [ "$REINSTALL" = true ] && [ -f "$BASE_DIR/secret.txt" ]; then
            read -p "Использовать старый секрет? (y/n) [y]: " use_old
            if [[ "$use_old" =~ ^[Yy]$ ]] || [ -z "$use_old" ]; then
                SECRET=$(cat "$BASE_DIR/secret.txt")
                SECRET_BASE=${SECRET:2:32}
                print_success "Использую существующий секрет"
                return
            fi
        fi
        
        read -p "Введите базовый секрет (32 hex) или Enter для генерации: " SECRET_BASE
        if [ -z "$SECRET_BASE" ]; then
            SECRET_BASE=$(openssl rand -hex 16)
            print_success "Сгенерирован базовый секрет: $SECRET_BASE"
        elif [[ ! $SECRET_BASE =~ ^[a-fA-F0-9]{32}$ ]]; then
            print_error "Ошибка: секрет должен содержать 32 hex символа"
            exit 1
        fi
        
        # Формируем полный секрет
        TLS_DOMAIN_HEX=$(echo -n "$TLS_DOMAIN" | xxd -p | tr -d '\n')
        SECRET="ee${SECRET_BASE}${TLS_DOMAIN_HEX}"
        print_success "Сформирован полный секрет"
    fi
    
    # Сохраняем секрет
    mkdir -p "$BASE_DIR"
    echo "$SECRET" > "$BASE_DIR/secret.txt"
    chmod 600 "$BASE_DIR/secret.txt"
}

# Установка Docker
install_docker() {
    if ! command -v docker &>/dev/null; then
        print_header "Установка Docker"
        print_info "Установка Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm /tmp/get-docker.sh
        print_success "Docker установлен"
    fi
    
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
}

# Создание конфигурации
create_config() {
    print_info "Создание конфигурации для режима $PROXY_MODE..."
    
    mkdir -p "$BASE_DIR/config"
    
    # Определяем API порт
    API_PORT=9091
    if [ "$PROXY_MODE" == "dd" ]; then
        API_PORT=9092
    elif [ "$PROXY_MODE" == "ee" ]; then
        API_PORT=9093
    elif [ "$EXISTING_DD" = true ]; then
        API_PORT=9092
    elif [ "$EXISTING_EE" = true ]; then
        API_PORT=9093
    fi
    
    if [ "$PROXY_MODE" == "classic" ]; then
        # Конфигурация для CLASSIC (обычный, без шифрования)
        cat > "$BASE_DIR/config/telemt.toml" << EOF
[general]
use_middle_proxy = true

[general.modes]
classic = true
secure = false
tls = false

[server]
port = $PORT
max_connections = 0

[server.api]
enabled = true
listen = "127.0.0.1:$API_PORT"

[access]
mode = "secret"

[access.users]
default = "$SECRET"
EOF
    elif [ "$PROXY_MODE" == "dd" ]; then
        # Конфигурация для DD (secure, с шифрованием)
        cat > "$BASE_DIR/config/telemt.toml" << EOF
[general]
use_middle_proxy = true

[general.modes]
classic = false
secure = true
tls = false

[server]
port = $PORT
max_connections = 0

[server.api]
enabled = true
listen = "127.0.0.1:$API_PORT"

[access]
mode = "secret"

[access.users]
default = "$SECRET"
EOF
    else
        # Конфигурация для EE (FakeTLS)
        cat > "$BASE_DIR/config/telemt.toml" << EOF
[general]
use_middle_proxy = true

[general.modes]
classic = false
secure = false
tls = true

[server]
port = $PORT
max_connections = 0

[server.api]
enabled = true
listen = "127.0.0.1:$API_PORT"

[censorship]
tls_domain = "$TLS_DOMAIN"
unknown_sni_action = "mask"
fallback_sni = "$TLS_DOMAIN"
fallback_content = "/"
strict_sni_check = false

[access]
mode = "secret"

[access.users]
default = "$SECRET_BASE"
EOF
    fi
    
    print_success "Конфигурация создана: $BASE_DIR/config/telemt.toml"
}

# Создание docker-compose.yml
create_compose() {
    print_info "Создание docker-compose.yml..."
    
    cat > "$BASE_DIR/docker-compose.yml" << EOF
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    network_mode: host
    environment:
      RUST_LOG: info
    volumes:
      - ./config:/etc/telemt:ro
    command: ["/etc/telemt/telemt.toml"]
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
EOF
    
    print_success "Docker-compose создан: $BASE_DIR/docker-compose.yml"
}

# Запуск контейнера
run_container() {
    cd "$BASE_DIR"
    
    print_info "Запуск контейнера $CONTAINER_NAME..."
    
    # Останавливаем старый контейнер если нужно
    if [ "$REINSTALL" = true ]; then
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
    fi
    
    # Загружаем образ
    print_info "Загрузка Docker образа..."
    docker pull whn0thacked/telemt-docker:latest
    
    # Запускаем
    docker compose up -d
    
    sleep 3
    
    if docker ps | grep -q "$CONTAINER_NAME"; then
        print_success "Контейнер $CONTAINER_NAME запущен"
        print_info "Логи контейнера:"
        docker logs "$CONTAINER_NAME" --tail 15
    else
        print_error "Ошибка запуска контейнера"
        docker logs "$CONTAINER_NAME" --tail 30 2>/dev/null || true
        exit 1
    fi
}

# Настройка firewall
configure_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -q "$PORT/tcp"; then
            ufw allow $PORT/tcp comment "TeleMT $PROXY_MODE"
            print_success "Порт $PORT открыт в UFW"
        fi
    fi
}

# Получение IP
get_public_ip() {
    print_info "Определение публичного IP..."
    
    PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    
    if [ -z "$PUBLIC_IP" ]; then
        read -p "Введите IP сервера: " PUBLIC_IP
    fi
    
    print_success "IP: $PUBLIC_IP"
}

# Вывод результата
print_result() {
    print_header "TeleMT Proxy установлен!"
    
    echo ""
    echo "📱 РЕЖИМ: $PROXY_MODE"
    
    # Описание режима
    case $PROXY_MODE in
        classic) 
            echo "📝 Описание: Обычный MTProto (без шифрования, уязвим к DPI)"
            echo "⚠️  Рекомендуется использовать только если другие режимы не работают"
            ;;
        dd) 
            echo "📝 Описание: Secure MTProto (с шифрованием, хороший баланс)"
            echo "✅ Рекомендуемый режим для повседневного использования"
            ;;
        ee) 
            echo "📝 Описание: FakeTLS (маскировка под HTTPS, лучший обход DPI)"
            echo "✅ Лучший режим для стран с жесткой цензурой"
            ;;
    esac
    
    echo ""
    echo "🔗 ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ:"
    echo ""
    
    case $PROXY_MODE in
        classic)
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${SECRET}${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "📝 Ручная настройка:"
            echo "   Сервер: $PUBLIC_IP"
            echo "   Порт: $PORT"
            echo "   Секрет: $SECRET"
            echo "   Шифрование: Нет"
            ;;
        dd)
            echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${MAGENTA}tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${SECRET}${NC}"
            echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "📝 Ручная настройка:"
            echo "   Сервер: $PUBLIC_IP"
            echo "   Порт: $PORT"
            echo "   Секрет: $SECRET"
            echo "   Шифрование: Включено"
            ;;
        ee)
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${SECRET}${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "📝 Ручная настройка:"
            echo "   Сервер: $PUBLIC_IP"
            echo "   Порт: $PORT"
            echo "   Секрет: $SECRET"
            echo "   Домен: $TLS_DOMAIN"
            echo "   Шифрование: Включено (FakeTLS)"
            ;;
    esac
    
    echo ""
    echo "📋 Команды управления:"
    echo "   Логи:      docker logs $CONTAINER_NAME -f"
    echo "   Остановка: docker stop $CONTAINER_NAME"
    echo "   Запуск:    docker start $CONTAINER_NAME"
    echo "   Перезапуск: docker restart $CONTAINER_NAME"
    echo ""
    
    # Показываем все прокси
    if [ "$EXISTING_CLASSIC" = true ] || [ "$EXISTING_DD" = true ] || [ "$EXISTING_EE" = true ]; then
        echo "📊 ВСЕ ПРОКСИ НА СЕРВЕРЕ:"
        echo ""
        
        if [ "$EXISTING_CLASSIC" = true ] && [ -f /opt/telemt-classic/secret.txt ]; then
            CLASSIC_PORT=$(grep -oP 'port = \K\d+' /opt/telemt-classic/config/telemt.toml 2>/dev/null || echo "8443")
            CLASSIC_SECRET=$(cat /opt/telemt-classic/secret.txt 2>/dev/null)
            echo "  ✅ CLASSIC: tg://proxy?server=${PUBLIC_IP}&port=${CLASSIC_PORT}&secret=${CLASSIC_SECRET}"
        fi
        
        if [ "$EXISTING_DD" = true ] && [ -f /opt/telemt-dd/secret.txt ]; then
            DD_PORT=$(grep -oP 'port = \K\d+' /opt/telemt-dd/config/telemt.toml 2>/dev/null || echo "8444")
            DD_SECRET=$(cat /opt/telemt-dd/secret.txt 2>/dev/null)
            echo "  ✅ DD: tg://proxy?server=${PUBLIC_IP}&port=${DD_PORT}&secret=${DD_SECRET}"
        fi
        
        if [ "$EXISTING_EE" = true ] && [ -f /opt/telemt-ee/secret.txt ]; then
            EE_PORT=$(grep -oP 'port = \K\d+' /opt/telemt-ee/config/telemt.toml 2>/dev/null || echo "8445")
            EE_SECRET=$(cat /opt/telemt-ee/secret.txt 2>/dev/null)
            echo "  ✅ EE: tg://proxy?server=${PUBLIC_IP}&port=${EE_PORT}&secret=${EE_SECRET}"
        fi
        
        if [ "$REINSTALL" != true ]; then
            echo "  🆕 $PROXY_MODE (новый): tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${SECRET}"
        fi
    fi
    
    echo ""
    echo "========================================="
}

# Тестирование
test_proxy() {
    sleep 2
    
    if docker ps | grep -q "$CONTAINER_NAME"; then
        print_success "Контейнер работает"
        
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -qi "error\|panic"; then
            print_warning "Есть ошибки в логах"
        else
            print_success "Ошибок не обнаружено"
        fi
        
        # Проверяем режим в логах
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Modes:"; then
            MODES_LINE=$(docker logs "$CONTAINER_NAME" 2>&1 | grep "Modes:" | tail -1)
            print_info "Режимы: $MODES_LINE"
        fi
    else
        print_error "Контейнер не запущен"
    fi
}

# Главная функция
main() {
    print_header "TeleMT Proxy Installer v2.0"
    echo "Поддерживаемые режимы:"
    echo "  • CLASSIC - обычный MTProto (без шифрования)"
    echo "  • DD - secure MTProto (с шифрованием)"
    echo "  • EE - FakeTLS (маскировка под HTTPS)"
    echo ""
    
    check_root
    install_deps
    install_docker
    check_existing_containers
    select_mode
    get_config
    create_config
    create_compose
    run_container
    configure_firewall
    get_public_ip
    test_proxy
    print_result
}

# Запуск
main