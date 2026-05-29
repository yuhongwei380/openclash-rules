#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${red}致命错误: ${plain} 请使用 root 权限运行此脚本 \n " && exit 1

# 检查操作系统并设置发行版变量
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "检查系统操作系统失败，请联系作者！" >&2
    exit 1
fi
echo "系统发行版为: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}不支持的 CPU 架构！ ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "系统架构: $(arch)"

# 简单的辅助函数
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# 端口辅助函数
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y cronie curl tar tzdata socat ca-certificates openssl
            else
                dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm cronie curl tar tzdata socat ca-certificates openssl
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y cron curl tar timezone socat ca-certificates openssl
            ;;
        alpine)
            apk update && apk add dcron curl tar tzdata socat ca-certificates openssl
            ;;
        *)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
    esac
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

install_postgres_local() {
    local pg_user pg_pass
    pg_pass=$(gen_random_string 24)
    local pg_db="xui"
    local pg_host="127.0.0.1"
    local pg_port="5432"

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql-server postgresql-contrib >&2 || return 1
            else
                dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            fi
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        arch | manjaro | parch)
            pacman -Syu --noconfirm postgresql >&2 || return 1
            if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
                sudo -u postgres initdb -D /var/lib/postgres/data >&2 || return 1
            fi
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql-server postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
                install -d -o postgres -g postgres -m 700 /var/lib/pgsql/data >&2 || return 1
                su - postgres -c "initdb -D /var/lib/pgsql/data" >&2 || return 1
            fi
            ;;
        alpine)
            apk add --no-cache postgresql postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/postgresql/data/PG_VERSION ]]; then
                /etc/init.d/postgresql setup >&2 || return 1
            fi
            rc-update add postgresql default >&2 2> /dev/null || true
            rc-service postgresql start >&2 || return 1
            ;;
        *)
            echo -e "${red}不支持自动安装 PostgreSQL 的发行版: ${release}${plain}" >&2
            return 1
            ;;
    esac

    if [[ "${release}" != "alpine" ]]; then
        systemctl enable --now postgresql >&2 || return 1
    fi

    # 稍等片刻，等待服务器接受连接
    local i
    for i in 1 2 3 4 5; do
        sudo -u postgres psql -tAc 'SELECT 1' > /dev/null 2>&1 && break
        sleep 1
    done

    local existing_owner=""
    existing_owner=$(sudo -u postgres psql -tAc \
        "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | tr -d '[:space:]')
    if [[ -n "${existing_owner}" && "${existing_owner}" != "postgres" ]]; then
        pg_user="${existing_owner}"
    else
        pg_user=$(gen_random_string 8)
    fi

    # 幂等性的角色/数据库创建
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')

    if [[ -n "${PG_CRED_FILE:-}" ]]; then
        local prev_umask
        prev_umask=$(umask)
        umask 077
        if ! cat > "${PG_CRED_FILE}" << EOF; then
PG_USER=${pg_user}
PG_PASS=${pg_pass}
PG_HOST=${pg_host}
PG_PORT=${pg_port}
PG_DB=${pg_db}
EOF
            umask "${prev_umask}"
            echo -e "${red}未能将 PostgreSQL 凭据写入 ${PG_CRED_FILE}${plain}" >&2
            return 1
        fi
        umask "${prev_umask}"
    fi

    echo "postgres://${pg_user}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
    return 0
}

install_acme() {
    echo -e "${green}正在安装 acme.sh 用于 SSL 证书管理...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${red}安装 acme.sh 失败${plain}"
        return 1
    else
        echo -e "${green}acme.sh 安装成功${plain}"
    fi
    return 0
}

setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"

    echo -e "${green}正在设置 SSL 证书...${plain}"

    # 检查是否安装了 acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}安装 acme.sh 失败，跳过 SSL 设置${plain}"
            return 1
        fi
    fi

    # 创建证书目录
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"

    # 签发证书
    echo -e "${green}正在为 ${domain} 签发 SSL 证书...${plain}"
    echo -e "${yellow}注意：端口 80 必须开放并允许互联网访问${plain}"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force

    if [ $? -ne 0 ]; then
        echo -e "${yellow}为 ${domain} 签发证书失败${plain}"
        echo -e "${yellow}请确保端口 80 已开放，稍后使用 x-ui 命令重试${plain}"
        rm -rf ~/.acme.sh/${domain} 2> /dev/null
        rm -rf "$certPath" 2> /dev/null
        return 1
    fi

    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${yellow}安装证书失败${plain}"
        return 1
    fi

    # 启用自动续期
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    # 确保权限安全：私钥仅所有者可读
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # 为面板设置证书
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" > /dev/null 2>&1
        echo -e "${green}SSL 证书安装并配置成功！${plain}"
        return 0
    else
        echo -e "${yellow}未找到证书文件${plain}"
        return 1
    fi
}

# 使用短效配置文件（~6天有效期）签发 Let's Encrypt IP 证书
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2" # 可选

    echo -e "${green}正在设置 Let's Encrypt IP 证书 (shortlived 配置文件)...${plain}"
    echo -e "${yellow}注意：IP 证书有效期约为 6 天，并且会自动续期。${plain}"
    echo -e "${yellow}默认监听端口为 80。如果选择其他端口，请确保外部的 80 端口转发到该端口。${plain}"

    # 检查 acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}安装 acme.sh 失败${plain}"
            return 1
        fi
    fi

    # 验证 IP 地址
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}需要提供 IPv4 地址${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}无效的 IPv4 地址: $ipv4${plain}"
        return 1
    fi

    # 创建证书目录
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # 构建域名参数
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}正在包含 IPv6 地址: ${ipv6}${plain}"
    fi

    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    local WebPort=""
    read -rp "请提供用于 ACME HTTP-01 监听的端口 (默认 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}提供的端口无效。回退到 80 端口。${plain}"
        WebPort=80
    fi
    echo -e "${green}使用端口 ${WebPort} 进行独立验证。${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}提醒：Let's Encrypt 仍会连接 80 端口；请将外部的 80 端口转发到 ${WebPort}。${plain}"
    fi

    # 确保选择的端口可用
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}端口 ${WebPort} 已被占用。${plain}"

            local alt_port=""
            read -rp "请输入另一个用于 acme.sh 独立监听的端口 (留空则中止): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}端口 ${WebPort} 忙碌；无法继续。${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}提供的端口无效。${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}端口 ${WebPort} 空闲，准备进行独立验证。${plain}"
            break
        fi
    done

    # 签发证书
    echo -e "${green}正在为 ${ipv4} 签发 IP 证书...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1

    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}签发 IP 证书失败${plain}"
        echo -e "${yellow}请确保端口 ${WebPort} 可访问 (或从外部端口 80 转发过来)${plain}"
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书签发成功，正在安装...${plain}"

    ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}安装后未找到证书文件${plain}"
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书文件安装成功${plain}"

    # 启用 acme.sh 的自动升级
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1

    chmod 600 ${certDir}/privkey.pem 2> /dev/null
    chmod 644 ${certDir}/fullchain.pem 2> /dev/null

    echo -e "${green}正在为面板设置证书路径...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"

    if [ $? -ne 0 ]; then
        echo -e "${yellow}警告：无法自动设置证书路径${plain}"
        echo -e "${yellow}证书文件位于：${plain}"
        echo -e "  证书: ${certDir}/fullchain.pem"
        echo -e "  私钥:  ${certDir}/privkey.pem"
    else
        echo -e "${green}证书路径配置成功${plain}"
    fi

    echo -e "${green}IP 证书安装并配置成功！${plain}"
    echo -e "${green}证书有效期约为 6 天，通过 acme.sh 的计划任务自动续期。${plain}"
    echo -e "${yellow}acme.sh 将在证书过期前自动续期并重载 x-ui。${plain}"
    return 0
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "未找到 acme.sh。现在开始安装..."
        cd ~ || return 1
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${red}安装 acme.sh 失败${plain}"
            return 1
        else
            echo -e "${green}acme.sh 安装成功${plain}"
        fi
    fi

    local domain=""
    while true; do
        read -rp "请输入您的域名: " domain
        domain="${domain// /}" 

        if [[ -z "$domain" ]]; then
            echo -e "${red}域名不能为空。请重试。${plain}"
            continue
        fi

        if ! is_domain "$domain"; then
            echo -e "${red}无效的域名格式: ${domain}。请输入有效的域名。${plain}"
            continue
        fi

        break
    done
    echo -e "${green}您的域名是: ${domain}，正在检查...${plain}"
    SSL_ISSUED_DOMAIN="${domain}"

    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        cert_exists=1
        local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
        echo -e "${yellow}找到 ${domain} 的现有证书，将重复使用。${plain}"
        [[ -n "${certInfo}" ]] && echo "$certInfo"
    else
        echo -e "${green}您的域名现在已准备好签发证书...${plain}"
    fi

    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    local WebPort=80
    read -rp "请选择要使用的端口 (默认是 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        echo -e "${yellow}您的输入 ${WebPort} 无效，将使用默认端口 80。${plain}"
        WebPort=80
    fi
    echo -e "${green}将使用端口: ${WebPort} 签发证书。请确保此端口已开放。${plain}"

    echo -e "${yellow}正在暂时停止面板...${plain}"
    systemctl stop x-ui 2> /dev/null || rc-service x-ui stop 2> /dev/null

    if [[ ${cert_exists} -eq 0 ]]; then
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            echo -e "${red}签发证书失败，请检查日志。${plain}"
            rm -rf ~/.acme.sh/${domain}
            systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
            return 1
        else
            echo -e "${green}签发证书成功，正在安装证书...${plain}"
        fi
    else
        echo -e "${green}使用现有证书，正在安装证书...${plain}"
    fi

    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
    echo -e "${green}ACME 的默认 --reloadcmd 为: ${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
    echo -e "${green}此命令将在每次证书签发和续期时运行。${plain}"
    read -rp "您想修改 ACME 的 --reloadcmd 吗？(y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; systemctl restart x-ui"
        echo -e "${green}\t2.${plain} 输入您自己的命令"
        echo -e "${green}\t0.${plain} 保持默认 reloadcmd"
        read -rp "选择一个选项: " choice
        case "$choice" in
            1)
                echo -e "${green}Reloadcmd 为: systemctl reload nginx ; systemctl restart x-ui${plain}"
                reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
                ;;
            2)
                echo -e "${yellow}建议将 x-ui restart 放在最后${plain}"
                read -rp "请输入您的自定义 reloadcmd: " reloadCmd
                echo -e "${green}Reloadcmd 为: ${reloadCmd}${plain}"
                ;;
            *)
                echo -e "${green}保持默认 reloadcmd${plain}"
                ;;
        esac
    fi

    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        echo -e "${green}安装证书成功，正在启用自动续期...${plain}"
    else
        echo -e "${red}安装证书失败，退出。${plain}"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain}
        fi
        systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
        return 1
    fi

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}自动续期设置出现问题，证书详情：${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    else
        echo -e "${green}自动续期成功，证书详情：${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    fi

    systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null

    read -rp "您想将此证书设置到面板吗？(y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            echo -e "${green}已为面板设置证书路径${plain}"
            echo -e "${green}证书文件: $webCertFile${plain}"
            echo -e "${green}私钥文件: $webKeyFile${plain}"
            echo ""
            echo -e "${green}访问 URL: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${yellow}面板将重启以应用 SSL 证书...${plain}"
            systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
        else
            echo -e "${red}错误: 找不到域名 $domain 的证书或私钥文件。${plain}"
        fi
    else
        echo -e "${yellow}跳过面板路径设置。${plain}"
    fi

    return 0
}

prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"
    local server_ip="$3"

    local ssl_choice=""
    SSL_SCHEME="https"

    echo -e "${yellow}选择 SSL 证书设置方法：${plain}"
    echo -e "${green}1.${plain} 使用 Let's Encrypt 域名证书 (90天有效期，自动续期)"
    echo -e "${green}2.${plain} 使用 Let's Encrypt IP 证书 (6天有效期，自动续期)"
    echo -e "${green}3.${plain} 自定义 SSL 证书 (输入现有文件路径)"
    echo -e "${green}4.${plain} 跳过 SSL (高级 — 仅在反向代理 / SSH 隧道后方可用)"
    echo -e "${blue}注意：${plain} 选项 1 和 2 需要开放 80 端口。选项 3 需要手动输入路径。"
    echo -e "${blue}注意：${plain} 选项 4 将通过普通 HTTP 提供面板 — 仅在使用 nginx/Caddy 或 SSH 隧道时安全。"
    read -rp "选择一个选项 (默认 2 为 IP): " ssl_choice
    ssl_choice="${ssl_choice// /}" 

    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" && "$ssl_choice" != "4" ]]; then
        ssl_choice="2"
    fi

    case "$ssl_choice" in
        1)
            echo -e "${green}正在为域名证书使用 Let's Encrypt...${plain}"
            if ssl_cert_issue; then
                local cert_domain="${SSL_ISSUED_DOMAIN}"
                if [[ -z "${cert_domain}" ]]; then
                    cert_domain=$(~/.acme.sh/acme.sh --list 2> /dev/null | tail -1 | awk '{print $1}')
                fi

                if [[ -n "${cert_domain}" ]]; then
                    SSL_HOST="${cert_domain}"
                    echo -e "${green}✓ SSL 证书配置成功，域名: ${cert_domain}${plain}"
                else
                    echo -e "${yellow}SSL 设置可能已完成，但提取域名失败${plain}"
                    SSL_HOST="${server_ip}"
                fi
            else
                echo -e "${red}域名模式下的 SSL 证书设置失败。${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        2)
            echo -e "${green}正在为 IP 证书使用 Let's Encrypt (shortlived 配置文件)...${plain}"

            local ipv6_addr=""
            read -rp "您有要包含的 IPv6 地址吗？(留空则跳过): " ipv6_addr
            ipv6_addr="${ipv6_addr// /}"

            if [[ $release == "alpine" ]]; then
                rc-service x-ui stop > /dev/null 2>&1
            else
                systemctl stop x-ui > /dev/null 2>&1
            fi

            setup_ip_certificate "${server_ip}" "${ipv6_addr}"
            if [ $? -eq 0 ]; then
                SSL_HOST="${server_ip}"
                echo -e "${green}✓ Let's Encrypt IP 证书配置成功${plain}"
            else
                echo -e "${red}✗ IP 证书设置失败。请检查 80 端口是否已开放。${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        3)
            echo -e "${green}使用自定义的现有证书...${plain}"
            local custom_cert=""
            local custom_key=""
            local custom_domain=""

            read -rp "请输入签发证书的域名: " custom_domain
            custom_domain="${custom_domain// /}"

            while true; do
                read -rp "输入证书路径 (关键词: .crt / fullchain): " custom_cert
                custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                    break
                elif [[ ! -f "$custom_cert" ]]; then
                    echo -e "${red}错误：文件不存在！请重试。${plain}"
                elif [[ ! -r "$custom_cert" ]]; then
                    echo -e "${red}错误：文件存在但不可读 (请检查权限)！${plain}"
                else
                    echo -e "${red}错误：文件为空！${plain}"
                fi
            done

            while true; do
                read -rp "输入私钥路径 (关键词: .key / privatekey): " custom_key
                custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                    break
                elif [[ ! -f "$custom_key" ]]; then
                    echo -e "${red}错误：文件不存在！请重试。${plain}"
                elif [[ ! -r "$custom_key" ]]; then
                    echo -e "${red}错误：文件存在但不可读 (请检查权限)！${plain}"
                else
                    echo -e "${red}错误：文件为空！${plain}"
                fi
            done

            ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" > /dev/null 2>&1

            if [[ -n "$custom_domain" ]]; then
                SSL_HOST="$custom_domain"
            else
                SSL_HOST="${server_ip}"
            fi

            echo -e "${green}✓ 自定义证书路径已应用。${plain}"
            echo -e "${yellow}注意：您负责在外部续期这些文件。${plain}"

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            ;;
        4)
            echo ""
            echo -e "${red}⚠ 面板将在【不开启】 SSL/TLS 的情况下安装。${plain}"
            echo -e "${yellow}登录凭据和 cookie 将以明文 HTTP 传输。${plain}"
            echo -e "${yellow}仅在以下情况安全：${plain}"
            echo -e "${yellow}  • 由反向代理 (nginx, Caddy, Traefik) 为您终止 TLS，或者${plain}"
            echo -e "${yellow}  • 您仅通过 SSH 隧道访问面板${plain}"
            echo ""

            SSL_SCHEME="http"
            SSL_HOST="${server_ip}"

            local bind_local=""
            read -rp "仅将面板绑定到 127.0.0.1 吗？(推荐 — 强制 SSH 隧道 / 反向代理访问) [y/N]: " bind_local
            if [[ "$bind_local" == "y" || "$bind_local" == "Y" ]]; then
                ${xui_folder}/x-ui setting -listenIP "127.0.0.1" > /dev/null 2>&1
                SSL_HOST="127.0.0.1"
                echo -e "${green}✓ 面板仅绑定到 127.0.0.1。它现在无法从公共互联网访问。${plain}"
                echo ""
                echo -e "${green}SSH 端口转发 — 通过以下方式从本地计算机打开面板：${plain}"
                echo -e "  标准 SSH 命令:"
                echo -e "  ${yellow}ssh -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  如果使用 SSH 密钥:"
                echo -e "  ${yellow}ssh -i <sshkeypath> -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  然后在浏览器中打开:"
                echo -e "  ${yellow}http://localhost:2222/${web_base_path}${plain}"
                echo ""
                echo -e "${yellow}替代方案：将反向代理 (nginx/Caddy) 指向 127.0.0.1:${panel_port} 并让其终止 TLS。${plain}"
            else
                echo -e "${yellow}面板将在所有接口上通过明文 HTTP 监听。请确保前面有其他服务处理 TLS。${plain}"
            fi

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            echo -e "${green}✓ 跳过 SSL 设置。${plain}"
            ;;
        *)
            echo -e "${red}无效选项。跳过 SSL 设置。${plain}"
            SSL_HOST="${server_ip}"
            ;;
    esac
}

config_after_install() {
    local existing_hasDefaultCredential=$(${xui_folder}/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}无法从任何提供商自动检测服务器 IP。${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入服务器的公共 IPv4 地址: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}无效的 IPv4 地址。请重试。${plain}"
                server_ip=""
            fi
        done
    fi

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath=$(gen_random_string 18)
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            local db_label="SQLite (/etc/x-ui/x-ui.db)"
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     数据库选择                            ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "  1) SQLite     (默认 — 推荐客户端数量 < 500 时使用)"
            echo -e "  2) PostgreSQL (推荐高客户端数量 / 多节点时使用)"
            read -rp "请选择 [1]: " db_choice
            db_choice="${db_choice:-1}"
            if [[ "$db_choice" == "2" ]]; then
                local xui_env_file
                case "${release}" in
                    ubuntu | debian | armbian)
                        xui_env_file="/etc/default/x-ui"
                        ;;
                    arch | manjaro | parch | alpine)
                        xui_env_file="/etc/conf.d/x-ui"
                        ;;
                    *)
                        xui_env_file="/etc/sysconfig/x-ui"
                        ;;
                esac

                local xui_dsn=""
                local pg_mode=""
                local pg_local_installed=0
                while [[ -z "$xui_dsn" ]]; do
                    echo ""
                    echo -e "  1) 本地安装 PostgreSQL 并创建专用用户/数据库 (推荐)"
                    echo -e "  2) 使用现有的 PostgreSQL 服务器 (输入 DSN)"
                    read -rp "请选择 [1]: " pg_mode
                    pg_mode="${pg_mode:-1}"
                    if [[ "$pg_mode" == "2" ]]; then
                        while [[ -z "$xui_dsn" ]]; do
                            read -rp "输入 PostgreSQL DSN (postgres://user:pass@host:port/dbname?sslmode=disable): " xui_dsn
                            xui_dsn="${xui_dsn// /}"
                        done
                        db_label="PostgreSQL (外部)"
                    else
                        echo -e "${yellow}正在安装 PostgreSQL — 这可能需要一点时间...${plain}"
                        local pg_cred_file
                        pg_cred_file=$(mktemp 2> /dev/null) || pg_cred_file=$(mktemp -t x-ui-pg-creds.XXXXXXXX)
                        if [[ -z "${pg_cred_file}" ]]; then
                            echo -e "${red}无法创建临时凭据文件。${plain}"
                            xui_dsn=""
                            continue
                        fi
                        if xui_dsn=$(PG_CRED_FILE="${pg_cred_file}" install_postgres_local); then
                            pg_local_installed=1
                            if [[ -r "${pg_cred_file}" ]]; then
                                source "${pg_cred_file}"
                            fi
                            rm -f "${pg_cred_file}"
                            db_label="PostgreSQL (${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB})"
                        else
                            rm -f "${pg_cred_file}"
                            echo ""
                            echo -e "${red}PostgreSQL 安装失败。${plain}"
                            echo -e "  1) 重试本地安装"
                            echo -e "  2) 改为输入外部 DSN"
                            echo -e "  3) 放弃安装"
                            echo -e "  4) 回退到 SQLite"
                            read -rp "请选择 [1]: " pg_fail
                            pg_fail="${pg_fail:-1}"
                            case "$pg_fail" in
                                2) pg_mode="2" ;;
                                3)
                                    echo -e "${red}安装已放弃。${plain}"
                                    exit 1
                                    ;;
                                4)
                                    db_choice="1"
                                    xui_dsn=""
                                    break
                                    ;;
                                *) xui_dsn="" ;;
                            esac
                        fi
                    fi
                done
                if [[ -n "$xui_dsn" ]]; then
                    install -d -m 755 "$(dirname "$xui_env_file")"
                    umask 077
                    cat > "$xui_env_file" << EOF
XUI_DB_TYPE=postgres
XUI_DB_DSN=${xui_dsn}
EOF
                    chmod 600 "$xui_env_file"
                    umask 022
                    export XUI_DB_TYPE=postgres
                    export XUI_DB_DSN="${xui_dsn}"
                fi
            fi

            read -rp "您想自定义面板端口设置吗？(如果不想，将应用随机端口) [y/n]: " config_confirm
            if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                read -rp "请设置面板端口: " config_port
                echo -e "${yellow}您的面板端口为: ${config_port}${plain}"
            else
                local config_port=$(shuf -i 1024-62000 -n 1)
                echo -e "${yellow}生成随机端口: ${config_port}${plain}"
            fi

            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"

            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     SSL 证书设置 (推荐)                   ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}强烈建议使用 SSL。除非由反向代理${plain}"
            echo -e "${yellow}或 SSH 隧道为您处理 TLS，否则请勿跳过。${plain}"
            echo -e "${yellow}Let's Encrypt 现在同时支持域名和 IP 地址！${plain}"
            echo ""

            prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}"

            local config_apiToken=$(${xui_folder}/x-ui setting -getApiToken true | grep -Eo 'apiToken: .+' | awk '{print $2}')

            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     面板安装完成！                       ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}用户名:      ${config_username}${plain}"
            echo -e "${green}密码:        ${config_password}${plain}"
            echo -e "${green}端口:        ${config_port}${plain}"
            echo -e "${green}WebBasePath: ${config_webBasePath}${plain}"
            echo -e "${green}数据库:      ${db_label}${plain}"
            echo -e "${green}访问 URL:    ${SSL_SCHEME}://${SSL_HOST}:${config_port}/${config_webBasePath}${plain}"
            echo -e "${green}API Token:   ${config_apiToken}${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}⚠ 重要：请妥善保存这些凭据！${plain}"
            if [[ "$SSL_SCHEME" == "https" ]]; then
                echo -e "${yellow}⚠ SSL 证书：已启用并配置${plain}"
            else
                echo -e "${yellow}⚠ SSL 证书：已跳过 — 面板仅支持 HTTP。请使用反向代理或 SSH 隧道。${plain}"
            fi

            if [[ "$db_choice" == "2" && "$pg_local_installed" == "1" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     PostgreSQL 凭据                      ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}数据库名:   ${PG_DB}${plain}"
                echo -e "${green}用户名:     ${PG_USER}${plain}"
                echo -e "${green}密码:       ${PG_PASS}${plain}"
                echo -e "${green}主机:       ${PG_HOST}${plain}"
                echo -e "${green}端口:       ${PG_PORT}${plain}"
                echo -e "${green}DSN:        ${xui_dsn}${plain}"
                echo -e "${green}环境文件:   ${xui_env_file}${plain}"
                echo -e "${green}-------------------------------------------${plain}"
                echo -e "${green}从此服务器连接：${plain}"
                echo -e "  ${blue}sudo -u postgres psql -d ${PG_DB}${plain}      (作为 postgres 超级用户)"
                echo -e "  ${blue}PGPASSWORD='${PG_PASS}' psql -h ${PG_HOST} -p ${PG_PORT} -U ${PG_USER} -d ${PG_DB}${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}⚠ 面板从 ${xui_env_file} 读取这些凭据。${plain}"
                echo -e "${yellow}⚠ 请保存密码 — 它不会以明文形式存储在其他任何地方。${plain}"
                unset PG_USER PG_PASS PG_HOST PG_PORT PG_DB
            fi
        else
            local config_webBasePath=$(gen_random_string 18)
            echo -e "${yellow}WebBasePath 丢失或过短。正在生成新的 WebBasePath...${plain}"
            ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}新的 WebBasePath: ${config_webBasePath}${plain}"

            if [[ -z "${existing_cert}" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     SSL 证书设置 (推荐)                   ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}Let's Encrypt 现在同时支持域名和 IP 地址！${plain}"
                echo ""
                prompt_and_setup_ssl "${existing_port}" "${config_webBasePath}" "${server_ip}"
                echo -e "${green}访问 URL:  ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${config_webBasePath}${plain}"
            else
                echo -e "${green}访问 URL: https://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
            fi
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            echo -e "${yellow}检测到默认凭据。需要进行安全更新...${plain}"
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "生成了新的随机登录凭据："
            echo -e "###############################################"
            echo -e "${green}用户名: ${config_username}${plain}"
            echo -e "${green}密码: ${config_password}${plain}"
            echo -e "###############################################"
        else
            echo -e "${green}用户名、密码和 WebBasePath 已正确设置。${plain}"
        fi

        existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        if [[ -z "$existing_cert" ]]; then
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     SSL 证书设置 (推荐)                   ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}Let's Encrypt 现在同时支持域名和 IP 地址！${plain}"
            echo ""
            prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
            echo -e "${green}访问 URL:  ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        else
            echo -e "${green}SSL 证书已配置。无需任何操作。${plain}"
        fi
    fi

    ${xui_folder}/x-ui migrate
}

install_x-ui() {
    cd ${xui_folder%/x-ui}/

    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}正在尝试使用 IPv4 获取版本...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}获取 x-ui 版本失败，可能是由于 GitHub API 限制，请稍后再试${plain}"
                exit 1
            fi
        fi
        echo -e "获取到 x-ui 最新版本: ${tag_version}，开始安装..."
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 x-ui 失败，请确保您的服务器可以访问 GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"

        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}请使用较新版本 (至少 v2.3.5)。退出安装。${plain}"
            exit 1
        fi

        url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "开始安装 x-ui $1"
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 x-ui $1 失败，请检查该版本是否存在 ${plain}"
            exit 1
        fi
    fi
    curl -4fLRo /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 x-ui.sh 失败${plain}"
        exit 1
    fi

    if [[ -e ${xui_folder}/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm ${xui_folder}/ -rf
    fi

    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f

    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh

    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)

    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    config_after_install

    if [ -d "/etc/.git" ]; then
        if [ -f "/etc/.gitignore" ]; then
            if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
                echo "" >> "/etc/.gitignore"
                echo "x-ui/x-ui.db" >> "/etc/.gitignore"
                echo -e "${green}已将 x-ui.db 添加到 /etc/.gitignore 以适配 etckeeper${plain}"
            fi
        else
            echo "x-ui/x-ui.db" > "/etc/.gitignore"
            echo -e "${green}已创建 /etc/.gitignore 并添加 x-ui.db 以适配 etckeeper${plain}"
        fi
    fi

    if [[ $release == "alpine" ]]; then
        curl -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 x-ui.rc 失败${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        service_installed=false

        if [ -f "x-ui.service" ]; then
            echo -e "${green}在提取的文件中找到 x-ui.service，正在安装...${plain}"
            cp -f x-ui.service ${xui_service}/ > /dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                service_installed=true
            fi
        fi

        if [ "$service_installed" = false ]; then
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}在提取的文件中找到 x-ui.service.debian，正在安装...${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}在提取的文件中找到 x-ui.service.arch，正在安装...${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}在提取的文件中找到 x-ui.service.rhel，正在安装...${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac
        fi

        if [ "$service_installed" = false ]; then
            echo -e "${yellow}在 tar.gz 中未找到服务文件，正在从 GitHub 下载...${plain}"
            case "${release}" in
                ubuntu | debian | armbian)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian > /dev/null 2>&1
                    ;;
                arch | manjaro | parch)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.arch > /dev/null 2>&1
                    ;;
                *)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.rhel > /dev/null 2>&1
                    ;;
            esac

            if [[ $? -ne 0 ]]; then
                echo -e "${red}从 GitHub 安装 x-ui.service 失败${plain}"
                exit 1
            fi
            service_installed=true
        fi

        if [ "$service_installed" = true ]; then
            echo -e "${green}正在设置 systemd 单元...${plain}"
            chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        else
            echo -e "${red}安装 x-ui.service 文件失败${plain}"
            exit 1
        fi
    fi

    echo -e "${green}x-ui ${tag_version}${plain} 安装完成，现在正在运行..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui 控制菜单用法 (子命令):${plain}                           │
│                                                       │
│  ${blue}x-ui${plain}              - 管理脚本菜单                     │
│  ${blue}x-ui start${plain}        - 启动 x-ui 面板                   │
│  ${blue}x-ui stop${plain}         - 停止 x-ui 面板                   │
│  ${blue}x-ui restart${plain}      - 重启 x-ui 面板                   │
│  ${blue}x-ui status${plain}       - 查看 x-ui 状态                   │
│  ${blue}x-ui settings${plain}     - 查看当前设置                     │
│  ${blue}x-ui enable${plain}       - 设置 x-ui 开机自启               │
│  ${blue}x-ui disable${plain}      - 取消 x-ui 开机自启               │
│  ${blue}x-ui log${plain}          - 查看 x-ui 日志                   │
│  ${blue}x-ui banlog${plain}       - 查看 Fail2ban 封禁日志           │
│  ${blue}x-ui update${plain}       - 更新 x-ui 面板                   │
│  ${blue}x-ui legacy${plain}       - 遗留版本                         │
│  ${blue}x-ui install${plain}      - 安装 x-ui 面板                   │
│  ${blue}x-ui uninstall${plain}    - 卸载 x-ui 面板                   │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}运行中...${plain}"
install_base

# 提示用户输入版本号
read -rp "请输入要安装的 3x-ui 版本号 (例如 v2.3.8，直接回车则默认安装最新版): " user_version
# 去除输入中可能包含的空格
user_version="${user_version// /}"

if [[ -z "$user_version" ]]; then
    echo -e "${yellow}未检测到输入，准备安装最新版本...${plain}"
    install_x-ui
else
    echo -e "${green}准备安装指定版本: ${user_version}${plain}"
    install_x-ui "$user_version"
fi
