#!/bin/bash

# Docker 一键安装脚本 - 兼容 CentOS / Ubuntu / Debian / Fedora 等主流 Linux
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}        Docker 一键安装脚本（通用版）${NC}"
echo -e "${GREEN}=============================================${NC}"

# 检查是否 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 或 sudo 执行此脚本${NC}"
    exit 1
fi

# 下载官方安装脚本并执行
echo -e "${YELLOW}正在下载 Docker 官方安装脚本...${NC}"
curl -fsSL https://get.docker.com -o get-docker.sh

echo -e "${YELLOW}开始安装 Docker...${NC}"
sh get-docker.sh

# 清理临时文件
rm -f get-docker.sh

# 启动并设置开机自启
echo -e "${YELLOW}启动 Docker 并设置开机自启...${NC}"
systemctl start docker
systemctl enable docker

# 安装 docker-compose 插件（已内置，这里检查一下）
echo -e "${YELLOW}检查 Docker Compose 插件...${NC}"
docker compose version

# 验证安装
echo -e "${GREEN}验证 Docker 安装...${NC}"
docker run --rm hello-world

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}Docker 安装完成！${NC}"
echo -e "${YELLOW}如需普通用户免 sudo 使用 docker：${NC}"
echo -e "  sudo usermod -aG docker \$USER"
echo -e "  然后退出当前终端重新登录即可${NC}"
echo -e "${GREEN}=============================================${NC}"



cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ]
}
EOF

systemctl daemon-reload
systemctl restart docker
