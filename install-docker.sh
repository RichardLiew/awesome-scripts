#!/bin/bash
#===============================================================================
#
#          FILE: install_docker.sh
#
#         USAGE: chmod +x install_docker.sh && sudo ./install_docker.sh
#
#   DESCRIPTION: 通用Docker安装脚本，支持Ubuntu/Debian/CentOS/RHEL/Fedora/
#                Arch Linux/Alpine/SUSE/openSUSE等主流Linux发行版
#
#       OPTIONS: -h 显示帮助, -t 安装测试镜像, -c 安装Docker Compose
#  REQUIREMENTS: root权限或sudo权限
#          BUGS: 报告到 https://github.com/yourrepo/issues
#         NOTES: 建议在执行前备份重要数据
#        AUTHOR: Assistant
#       VERSION: 2.0
#       CREATED: 2026-04-08
#===============================================================================

set -euo pipefail

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# 全局变量
INSTALL_COMPOSE=true
RUN_TEST=false
DOCKER_VERSION=""
LOG_FILE="/var/log/docker_install_$(date +%Y%m%d_%H%M%S).log"

#===============================================================================
# 日志函数
#===============================================================================

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 输出到控制台
    case $level in
        INFO)  echo -e "${BLUE}[INFO]${NC}  $message" ;;
        SUCCESS) echo -e "${GREEN}[OK]${NC}   $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERR]${NC}  $message" ;;
    esac
    
    # 写入日志文件
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

#===============================================================================
# 系统检测函数
#===============================================================================

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        NAME=$NAME
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VERSION=$(lsb_release -sr)
        NAME=$(lsb_release -sd)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$(echo "$DISTRIB_ID" | tr '[:upper:]' '[:lower:]')
        VERSION=$DISTRIB_RELEASE
        NAME=$DISTRIB_DESCRIPTION
    elif [ -f /etc/debian_version ]; then
        OS=debian
        VERSION=$(cat /etc/debian_version)
        NAME="Debian $VERSION"
    elif [ -f /etc/redhat-release ]; then
        OS=$(grep -oP '(?<=^)[A-Za-z]+' /etc/redhat-release | tr '[:upper:]' '[:lower:]')
        VERSION=$(grep -oP '[0-9]+' /etc/redhat-release | head -1)
        NAME=$(cat /etc/redhat-release)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VERSION=$(uname -r)
        NAME=$OS
    fi
    
    log INFO "检测到操作系统: $NAME ($OS $VERSION)"
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  DOCKER_ARCH="x86_64";;
        aarch64|arm64) DOCKER_ARCH="aarch64";;
        armv7l|armhf) DOCKER_ARCH="armhf";;
        s390x)   DOCKER_ARCH="s390x";;
        ppc64le) DOCKER_ARCH="ppc64le";;
        *)       log ERROR "不支持的架构: $ARCH"; exit 1;;
    esac
    log INFO "检测到架构: $ARCH"
}

#===============================================================================
# 前置检查
#===============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        if ! sudo -n true 2>/dev/null; then
            log ERROR "需要root权限或sudo访问权限"
            log INFO "请运行: sudo $0"
            exit 1
        fi
        SUDO="sudo"
        log INFO "使用sudo执行安装"
    else
        SUDO=""
        log INFO "以root用户运行"
    fi
}

check_internet() {
    log INFO "检查网络连接..."
    if ! curl -s --max-time 10 https://download.docker.com >/dev/null 2>&1; then
        if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
            log ERROR "无法连接到互联网，请检查网络配置"
            exit 1
        fi
        log WARN "Docker官方仓库连接较慢，将尝试使用镜像源"
        USE_MIRROR=true
    else
        USE_MIRROR=false
    fi
}

check_existing_docker() {
    if command -v docker &> /dev/null; then
        INSTALLED_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        log WARN "检测到已安装的Docker版本: $INSTALLED_VERSION"
        read -p "是否重新安装/更新? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log INFO "跳过安装"
            exit 0
        fi
        
        # 卸载旧版本
        log INFO "卸载旧版本Docker..."
        case $OS in
            ubuntu|debian)
                $SUDO apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
                ;;
            centos|rhel|fedora|rocky|almalinux|ol)
                $SUDO yum remove -y docker docker-client docker-client-latest docker-common \
                    docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
                ;;
            arch|manjaro)
                $SUDO pacman -Rns --noconfirm docker 2>/dev/null || true
                ;;
            alpine)
                $SUDO apk del docker 2>/dev/null || true
                ;;
            suse|opensuse*|sles)
                $SUDO zypper remove -y docker 2>/dev/null || true
                ;;
        esac
    fi
}

#===============================================================================
# 安装函数 - 各发行版
#===============================================================================

install_docker_ubuntu_debian() {
    log INFO "为 $OS 安装Docker..."
    
    # 更新包索引
    $SUDO apt-get update >> "$LOG_FILE" 2>&1
    
    # 安装依赖
    $SUDO apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common >> "$LOG_FILE" 2>&1
    
    # 添加Docker官方GPG密钥
    $SUDO install -m 0755 -d /etc/apt/keyrings
    
    if [ "$USE_MIRROR" = true ]; then
        # 使用阿里云镜像
        curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/$OS/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/$OS $(lsb_release -cs) stable" | \
            $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    else
        curl -fsSL https://download.docker.com/linux/$OS/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | \
            $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi
    
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    
    # 安装Docker
    $SUDO apt-get update >> "$LOG_FILE" 2>&1
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1
    
    start_and_enable_docker
}

install_docker_centos_rhel_fedora() {
    log INFO "为 $OS 安装Docker..."
    
    # 安装依赖
    $SUDO yum install -y yum-utils device-mapper-persistent-data lvm2 >> "$LOG_FILE" 2>&1
    
    # 添加仓库
    if [ "$USE_MIRROR" = true ]; then
        # 使用阿里云镜像
        $SUDO yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    else
        $SUDO yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    
    # 安装Docker
    $SUDO yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1
    
    start_and_enable_docker
}

install_docker_fedora_dnf() {
    log INFO "为 Fedora 使用dnf安装Docker..."
    
    $SUDO dnf -y install dnf-plugins-core >> "$LOG_FILE" 2>&1
    
    if [ "$USE_MIRROR" = true ]; then
        $SUDO dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/fedora/docker-ce.repo
    else
        $SUDO dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    fi
    
    $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1
    
    start_and_enable_docker
}

install_docker_arch() {
    log INFO "为 Arch Linux 安装Docker..."
    
    # 更新系统
    $SUDO pacman -Sy >> "$LOG_FILE" 2>&1
    
    # 安装Docker
    $SUDO pacman -S --noconfirm docker >> "$LOG_FILE" 2>&1
    
    start_and_enable_docker
}

install_docker_alpine() {
    log INFO "为 Alpine Linux 安装Docker..."
    
    # 更新并安装
    $SUDO apk update >> "$LOG_FILE" 2>&1
    $SUDO apk add docker docker-compose >> "$LOG_FILE" 2>&1
    
    # Alpine使用OpenRC
    $SUDO rc-update add docker boot >> "$LOG_FILE" 2>&1
    $SUDO service docker start >> "$LOG_FILE" 2>&1
    
    log SUCCESS "Docker服务已启动"
}

install_docker_suse() {
    log INFO "为 openSUSE/SLES 安装Docker..."
    
    # 添加Docker仓库
    if [ "$USE_MIRROR" = true ]; then
        $SUDO zypper addrepo https://mirrors.aliyun.com/docker-ce/linux/opensuse/docker-ce.repo
    else
        $SUDO zypper addrepo https://download.docker.com/linux/opensuse/docker-ce.repo
    fi
    
    # 刷新并安装
    $SUDO zypper --gpg-auto-import-keys refresh
    $SUDO zypper install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >> "$LOG_FILE" 2>&1
    
    start_and_enable_docker
}

install_docker_static() {
    log WARN "未识别的发行版，尝试使用静态二进制安装..."
    
    # 下载静态二进制包（适用于所有Linux）
    local version=${DOCKER_VERSION:-$(curl -s https://download.docker.com/linux/static/stable/$DOCKER_ARCH/ | grep -oP 'docker-\K[0-9.]+(?=\.tgz)' | sort -V | tail -1)}
    local download_url="https://download.docker.com/linux/static/stable/$DOCKER_ARCH/docker-${version}.tgz"
    
    if [ "$USE_MIRROR" = true ]; then
        download_url="https://mirrors.aliyun.com/docker-ce/linux/static/stable/$DOCKER_ARCH/docker-${version}.tgz"
    fi
    
    log INFO "下载Docker $version 静态二进制包..."
    
    cd /tmp
    curl -fsSL "$download_url" -o docker.tgz
    tar xzvf docker.tgz >> "$LOG_FILE" 2>&1
    
    $SUDO cp docker/* /usr/bin/
    
    # 创建systemd服务文件
    $SUDO tee /etc/systemd/system/docker.service > /dev/null <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF
    
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable docker
    $SUDO systemctl start docker
    
    # 清理
    rm -rf /tmp/docker /tmp/docker.tgz
    
    log SUCCESS "Docker静态安装完成"
}

start_and_enable_docker() {
    log INFO "启动Docker服务..."
    
    $SUDO systemctl daemon-reload >> "$LOG_FILE" 2>&1
    $SUDO systemctl enable docker >> "$LOG_FILE" 2>&1
    $SUDO systemctl start docker >> "$LOG_FILE" 2>&1
    
    # 等待服务启动
    sleep 2
    
    if $SUDO systemctl is-active --quiet docker; then
        log SUCCESS "Docker服务已成功启动"
    else
        log ERROR "Docker服务启动失败，请检查日志: journalctl -u docker"
        exit 1
    fi
}

#===============================================================================
# 后处理配置
#===============================================================================

configure_docker() {
    log INFO "配置Docker..."
    
    # 创建docker组
    if ! getent group docker >/dev/null; then
        $SUDO groupadd docker
        log INFO "已创建docker用户组"
    fi
    
    # 将当前用户添加到docker组
    if [ -n "$SUDO_USER" ]; then
        $SUDO usermod -aG docker "$SUDO_USER"
        log INFO "已将用户 $SUDO_USER 添加到docker组"
        log WARN "请重新登录或运行 'newgrp docker' 使权限生效"
    elif [ "$EUID" -ne 0 ] && [ -n "$USER" ]; then
        $SUDO usermod -aG docker "$USER"
        log INFO "已将用户 $USER 添加到docker组"
    fi
    
    # 配置镜像加速（中国用户）
    if [ "$USE_MIRROR" = true ]; then
        log INFO "配置Docker镜像加速..."
        $SUDO mkdir -p /etc/docker
        
        $SUDO tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF
        
        $SUDO systemctl restart docker
        log SUCCESS "镜像加速配置完成"
    fi
}

install_docker_compose() {
    if [ "$INSTALL_COMPOSE" = false ]; then
        return
    fi
    
    log INFO "安装Docker Compose..."
    
    # 检查是否已通过插件安装
    if docker compose version &>/dev/null; then
        log SUCCESS "Docker Compose插件已安装: $(docker compose version)"
        return
    fi
    
    # 安装独立版本
    local compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -oP '"tag_name": "\K[0-9.]+')
    local compose_url="https://github.com/docker/compose/releases/download/v${compose_version}/docker-compose-linux-${DOCKER_ARCH}"
    
    $SUDO curl -L "$compose_url" -o /usr/local/bin/docker-compose
    $SUDO chmod +x /usr/local/bin/docker-compose
    
    # 创建软链接
    $SUDO ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    
    log SUCCESS "Docker Compose安装完成: $(docker-compose --version)"
}

run_test() {
    if [ "$RUN_TEST" = false ]; then
        return
    fi
    
    log INFO "运行Docker测试..."
    
    if ! docker run --rm hello-world; then
        log ERROR "Docker测试运行失败"
        exit 1
    fi
    
    log SUCCESS "Docker测试成功！"
}

#===============================================================================
# 主函数
#===============================================================================

show_help() {
    cat << EOF
通用Docker安装脚本

用法: $0 [选项]

选项:
    -h, --help          显示帮助信息
    -c, --compose       同时安装Docker Compose
    -t, --test          安装后运行测试镜像
    -v, --version       指定Docker版本（仅静态安装有效）
    -m, --mirror        强制使用国内镜像源
    --uninstall         卸载Docker

示例:
    sudo $0                    # 基础安装
    sudo $0 -c -t              # 安装Docker+Compose并测试
    sudo $0 -v 24.0.7          # 安装指定版本

支持的系统:
    Ubuntu (16.04+)
    Debian (9+)
    CentOS (7+)
    RHEL (7+)
    Fedora (30+)
    Arch Linux / Manjaro
    Alpine Linux
    openSUSE / SLES
    其他（静态二进制安装）
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--compose)
                INSTALL_COMPOSE=true
                shift
                ;;
            -t|--test)
                RUN_TEST=true
                shift
                ;;
            -v|--version)
                DOCKER_VERSION="$2"
                shift 2
                ;;
            -m|--mirror)
                USE_MIRROR=true
                shift
                ;;
            --uninstall)
                uninstall_docker
                exit 0
                ;;
            *)
                log ERROR "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

uninstall_docker() {
    log WARN "开始卸载Docker..."
    
    $SUDO systemctl stop docker 2>/dev/null || true
    $SUDO systemctl disable docker 2>/dev/null || true
    
    case $OS in
        ubuntu|debian)
            $SUDO apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
            $SUDO apt-get autoremove -y
            ;;
        centos|rhel|fedora|rocky|almalinux)
            $SUDO yum remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
            ;;
        arch|manjaro)
            $SUDO pacman -Rns --noconfirm docker
            ;;
        alpine)
            $SUDO rc-update del docker boot 2>/dev/null || true
            $SUDO apk del docker
            ;;
        suse|opensuse*)
            $SUDO zypper remove -y docker-ce docker-ce-cli containerd.io
            ;;
    esac
    
    # 清理数据
    read -p "是否删除所有Docker数据（/var/lib/docker）? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        $SUDO rm -rf /var/lib/docker
        log INFO "Docker数据已清理"
    fi
    
    log SUCCESS "Docker已卸载"
}

main() {
    parse_args "$@"
    
    echo "=========================================="
    echo "      Docker 通用安装脚本 v2.0"
    echo "=========================================="
    echo ""
    
    # 初始化日志
    $SUDO mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    $SUDO chmod 666 "$LOG_FILE"
    
    log INFO "开始安装流程...日志保存至: $LOG_FILE"
    
    # 系统检测
    detect_os
    detect_arch
    check_root
    check_internet
    check_existing_docker
    
    # 执行安装
    case $OS in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali)
            install_docker_ubuntu_debian
            ;;
        centos|rhel|rocky|almalinux|ol|scientific)
            if [ "$OS" = "fedora" ] || [ "${VERSION%%.*}" -ge 30 ] 2>/dev/null; then
                install_docker_fedora_dnf
            else
                install_docker_centos_rhel_fedora
            fi
            ;;
        fedora)
            install_docker_fedora_dnf
            ;;
        arch|manjaro|endeavouros|garuda)
            install_docker_arch
            ;;
        alpine)
            install_docker_alpine
            ;;
        opensuse*|suse|sles)
            install_docker_suse
            ;;
        *)
            log WARN "未明确支持的发行版: $OS，尝试静态安装"
            install_docker_static
            ;;
    esac
    
    # 后处理
    configure_docker
    install_docker_compose
    run_test
    
    # 完成
    echo ""
    echo "=========================================="
    log SUCCESS "Docker 安装完成！"
    echo "=========================================="
    echo ""
    echo "版本信息:"
    docker --version
    docker compose version 2>/dev/null || true
    echo ""
    echo "常用命令:"
    echo "  docker ps           # 查看运行中的容器"
    echo "  docker images       # 查看本地镜像"
    echo "  docker --help       # 查看帮助"
    echo ""
    echo "日志文件: $LOG_FILE"
    
    if [ -n "$SUDO_USER" ] || [ "$EUID" -ne 0 ]; then
        echo ""
        log WARN "提示: 请重新登录或执行 'newgrp docker' 以使用免sudo运行docker"
    fi
}

# 执行主函数
main "$@"
