#!/bin/bash
#===============================================================================
#
#          FILE: deploy-redis.sh
#
#         USAGE: ./deploy-redis.sh [-p password] [-d workdir] [-h]
#
#   DESCRIPTION: 通用Redis Docker部署脚本，支持所有Linux发行版
#                自动适配root/sudo权限，支持自定义密码和工作目录
#
#       OPTIONS: -p 设置Redis密码, -d 设置工作目录, -h 显示帮助
#  REQUIREMENTS: Docker + Docker Compose
#       VERSION: 2.0
#       CREATED: 2026-04-08
#===============================================================================

set -euo pipefail

# 默认配置
DEFAULT_PASSWORD="password"
DEFAULT_WORKDIR="/opt/redis"
PASSWORD="${DEFAULT_PASSWORD}"
WORKDIR="${DEFAULT_WORKDIR}"

# 颜色输出
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# 日志函数
log() {
    local level=$1
    shift
    case $level in
        INFO)  echo -e "${BLUE}[INFO]${NC}  $*" ;;
        SUCCESS) echo -e "${GREEN[OK]${NC}   $*" ;;
        WARN)  echo -e "${YELLOW[WARN]${NC} $*" ;;
        ERROR) echo -e "${RED[ERR]${NC}  $*" ;;
    esac
}

# 显示帮助
show_help() {
    cat << EOF
Redis Docker 部署脚本

用法: $0 [选项]

选项:
    -p, --password      设置Redis密码 (默认: ${DEFAULT_PASSWORD})
    -d, --directory     设置工作目录 (默认: ${DEFAULT_WORKDIR})
    -h, --help          显示此帮助信息

示例:
    sudo $0                                    # 使用默认配置
    sudo $0 -p MySecurePass123                 # 自定义密码
    sudo $0 -d /data/redis -p MyPass           # 自定义目录和密码
    sudo $0 --password MyPass --directory /redis

注意:
    - 需要root权限或sudo权限
    - 会自动检测并安装Docker Compose（如未安装）
EOF
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--password)
                PASSWORD="$2"
                shift 2
                ;;
            -d|--directory)
                WORKDIR="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log ERROR "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 检测并设置权限工具
check_privilege() {
    if [ "$EUID" -eq 0 ]; then
        SUDO=""
        log INFO "以 root 用户运行"
    elif command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
        SUDO="sudo"
        log INFO "使用 sudo 执行操作"
    elif command -v sudo &> /dev/null; then
        log WARN "需要 sudo 权限，请输入密码:"
        if sudo -v; then
            SUDO="sudo"
            log INFO "sudo 认证成功"
        else
            log ERROR "获取 sudo 权限失败"
            exit 1
        fi
    else
        log ERROR "需要 root 权限或 sudo 命令"
        exit 1
    fi
}

# 检测Linux发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VERSION=$(lsb_release -sr)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VERSION=$(uname -r)
    fi
    log INFO "检测到操作系统: ${OS} ${VERSION}"
}

# 检查Docker是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        log ERROR "Docker 未安装，请先安装 Docker"
        log INFO "可以使用以下命令快速安装:"
        log INFO "curl -fsSL https://raw.githubusercontent.com/RichardLiew/awesome-scripts/refs/heads/master/install-docker.sh | sudo sh"
        exit 1
    fi
    
    if ! $SUDO docker info &> /dev/null; then
        log ERROR "Docker 服务未运行或无权限访问"
        exit 1
    fi
    
    local docker_version=$($SUDO docker --version | awk '{print $3}' | tr -d ',')
    log SUCCESS "Docker 版本: ${docker_version}"
}

# 检查并确保Docker Compose可用
check_compose() {
    # 优先检查插件版本 (docker compose)
    if $SUDO docker compose version &> /dev/null; then
        COMPOSE_CMD="$SUDO docker compose"
        local compose_version=$($SUDO docker compose version --short)
        log SUCCESS "Docker Compose 插件版本: ${compose_version}"
        return 0
    fi
    
    # 检查独立版本 (docker-compose)
    if command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="$SUDO docker-compose"
        local compose_version=$(docker-compose --version | awk '{print $3}' | tr -d ',')
        log SUCCESS "Docker Compose 独立版本: ${compose_version}"
        return 0
    fi
    
    # 未安装，尝试自动安装
    log ERROR "Docker Compose 未安装，请先安装 Docker Compose"
    log INFO "可以使用以下命令快速安装:"
    log INFO "curl -fsSL https://raw.githubusercontent.com/RichardLiew/awesome-scripts/refs/heads/master/install-docker.sh | sudo sh -- -c"
    return 1
}

# 创建目录结构
setup_directories() {
    log INFO "创建工作目录: ${WORKDIR}"
    
    # 创建目录
    $SUDO mkdir -p ${WORKDIR}/{data,conf,logs}
    
    # 设置所有权（优先使用当前用户，否则使用root）
    if [ -n "${SUDO_USER:-}" ]; then
        $SUDO chown -R ${SUDO_USER}:${SUDO_USER} ${WORKDIR}
        log INFO "目录所有权设置为: ${SUDO_USER}"
    elif [ "$EUID" -eq 0 ] && [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
        $SUDO chown -R ${USER}:${USER} ${WORKDIR}
        log INFO "目录所有权设置为: ${USER}"
    else
        # 保持root所有权，但设置适当权限
        $SUDO chmod -R 755 ${WORKDIR}
        log WARN "目录所有权保持为root，请确保Docker有权限访问"
    fi
    
    # 设置权限
    $SUDO chmod -R 755 ${WORKDIR}
    $SUDO chmod 777 ${WORKDIR}/data  # Redis需要写权限
    
    log SUCCESS "目录结构创建完成"
}

# 生成Redis配置文件
generate_redis_conf() {
    log INFO "生成 Redis 配置文件..."
    
    $SUDO tee ${WORKDIR}/conf/redis.conf > /dev/null << EOF
#===============================================================================
# Redis 配置文件 - 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
#===============================================================================

# 网络配置
bind 0.0.0.0
port 6379
protected-mode no

# 进程配置
daemonize no                    # Docker中必须设置为no
supervised no
pidfile /var/run/redis_6379.pid

# 数据目录
dir /data

# 安全设置
requirepass ${PASSWORD}

# 持久化配置 - RDB
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb

# 持久化配置 - AOF
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
aof-use-rdb-preamble yes

# 内存管理
maxmemory 512mb
maxmemory-policy allkeys-lru
maxmemory-samples 10

# 日志配置
loglevel notice
logfile /logs/redis.log

# 客户端配置
timeout 300
tcp-keepalive 300
maxclients 10000

# 慢查询日志
slowlog-log-slower-than 10000
slowlog-max-len 128

# 性能优化
hash-max-ziplist-entries 512
hash-max-ziplist-value 64
list-max-ziplist-size -2
list-compress-depth 0
set-max-intset-entries 512
zset-max-ziplist-entries 128
zset-max-ziplist-value 64
hll-sparse-max-bytes 3000
stream-node-max-bytes 4096
stream-node-max-entries 100
activerehashing yes
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
hz 10
dynamic-hz yes
aof-rewrite-incremental-fsync yes
rdb-save-incremental-fsync yes
EOF

    $SUDO chmod 644 ${WORKDIR}/conf/redis.conf
    log SUCCESS "Redis 配置文件已生成: ${WORKDIR}/conf/redis.conf"
}

# 生成Docker Compose文件
generate_compose_file() {
    log INFO "生成 Docker Compose 配置文件..."
    
    $SUDO tee ${WORKDIR}/docker-compose.yml > /dev/null << EOF
version: '3.8'

services:
  redis:
    image: redis:7-alpine
    container_name: redis
    hostname: redis-server
    restart: unless-stopped
    
    ports:
      - "6379:6379"
    
    volumes:
      - ${WORKDIR}/data:/data
      - ${WORKDIR}/logs:/logs
      - ${WORKDIR}/conf/redis.conf:/usr/local/etc/redis/redis.conf:ro
    
    command: redis-server /usr/local/etc/redis/redis.conf
    
    # 系统优化参数
    sysctls:
      - net.core.somaxconn=65535
    
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    
    # 健康检查
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 10s
    
    # 资源限制（可选，生产环境建议开启）
    # deploy:
    #   resources:
    #     limits:
    #       cpus: '1.0'
    #       memory: 1G
    #     reservations:
    #       cpus: '0.5'
    #       memory: 512M
    
    networks:
      - redis-network

networks:
  redis-network:
    driver: bridge
EOF

    $SUDO chmod 644 ${WORKDIR}/docker-compose.yml
    log SUCCESS "Docker Compose 文件已生成: ${WORKDIR}/docker-compose.yml"
}

# 启动Redis服务
start_redis() {
    log INFO "启动 Redis 服务..."
    
    cd ${WORKDIR}
    
    # 检查是否有已存在的容器
    if $SUDO docker ps -a --format '{{.Names}}' | grep -q "^redis$"; then
        log WARN "发现已存在的 Redis 容器，正在停止并移除..."
        $SUDO docker stop redis 2>/dev/null || true
        $SUDO docker rm redis 2>/dev/null || true
    fi
    
    # 拉取最新镜像并启动
    $COMPOSE_CMD pull
    $COMPOSE_CMD up -d
    
    # 等待服务启动
    log INFO "等待 Redis 服务启动..."
    sleep 3
    
    # 检查服务状态
    local retries=5
    while [ $retries -gt 0 ]; do
        if $SUDO docker ps --format '{{.Names}}:{{.Status}}' | grep -q "redis:Up"; then
            log SUCCESS "Redis 服务启动成功"
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done
    
    if [ $retries -eq 0 ]; then
        log ERROR "Redis 服务启动失败，请检查日志"
        $SUDO docker logs redis 2>&1 | tail -20
        exit 1
    fi
}

# 验证安装
verify_installation() {
    log INFO "验证 Redis 安装..."
    
    # 测试连接
    if $SUDO docker exec redis redis-cli -a "${PASSWORD}" ping | grep -q "PONG"; then
        log SUCCESS "Redis 连接测试通过"
    else
        log ERROR "Redis 连接测试失败"
        exit 1
    fi
    
    # 显示信息
    echo ""
    echo "=========================================="
    log SUCCESS "Redis 部署完成！"
    echo "=========================================="
    echo ""
    echo "连接信息:"
    echo "  主机: localhost"
    echo "  端口: 6379"
    echo "  密码: ${PASSWORD}"
    echo ""
    echo "连接命令:"
    echo "  docker exec -it redis redis-cli -a ${PASSWORD}"
    echo ""
    echo "管理命令:"
    echo "  查看日志: docker logs -f redis"
    echo "  停止服务: cd ${WORKDIR} && ${COMPOSE_CMD} down"
    echo "  重启服务: cd ${WORKDIR} && ${COMPOSE_CMD} restart"
    echo "  进入容器: docker exec -it redis sh"
    echo ""
    echo "配置文件位置:"
    echo "  Redis配置: ${WORKDIR}/conf/redis.conf"
    echo "  数据目录:  ${WORKDIR}/data"
    echo "  日志目录:  ${WORKDIR}/logs"
    echo ""
    echo "=========================================="
}

# 清理函数（脚本退出时执行）
cleanup() {
    if [ $? -ne 0 ]; then
        echo ""
        log ERROR "部署过程中出现错误，请检查上述日志"
        log INFO "如需清理，请手动删除: ${WORKDIR}"
    fi
}

# 主函数
main() {
    # 设置错误处理
    trap cleanup EXIT
    
    # 解析参数
    parse_args "$@"
    
    echo "=========================================="
    echo "      Redis Docker 部署脚本 v2.0"
    echo "=========================================="
    echo ""
    
    # 执行流程
    check_privilege
    check_docker
    check_compose
    setup_directories
    generate_redis_conf
    generate_compose_file
    start_redis
    verify_installation
}

# 执行主程序
main "$@"
