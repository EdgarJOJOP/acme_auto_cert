#!/usr/bin/env bash
# Acme 阿里云 DNS API 精简版 for Debian/Ubuntu
# 仅保留：阿里云 DNS API 申请证书、安装证书、查询、一键续签、卸载

# 如果不是 bash，自动切换为 bash 重新执行
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

export LANG=en_US.UTF-8

red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue(){ echo -e "\033[36m\033[01m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请以 root 模式运行脚本" && exit 1

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
fi

if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* ]]; then
    red "当前脚本仅适配 Debian/Ubuntu 系统"
    exit 1
fi

ACME="$HOME/.acme.sh/acme.sh"
CERT_DIR="/etc/nginx"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/private.key"

install_deps(){
    if command -v curl >/dev/null 2>&1 && \
       command -v openssl >/dev/null 2>&1 && \
       command -v crontab >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
        return 0
    fi

    green "首次安装/补全必要依赖……"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl wget tar git openssl cron ca-certificates

    systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
}

ensure_acme(){
    if [[ -x "$ACME" ]]; then
        return 0
    fi

    echo
    yellow "首次安装 acme.sh，请输入注册邮箱（回车自动生成虚拟邮箱）："
    read -r Aemail

    if [[ -z "$Aemail" ]]; then
        auto=$(date +%s%N | md5sum | cut -c 1-6)
        Aemail="${auto}@gmail.com"
    fi

    green "开始安装 acme.sh，注册邮箱：$Aemail"

    # 先尝试官方安装脚本
    curl -L --connect-timeout 10 --max-time 180 https://get.acme.sh | sh -s email="$Aemail" >/dev/null 2>&1 || true

    # 官方失败则用 Gitee 镜像
    if [[ ! -x "$ACME" ]]; then
        yellow "官方源安装失败，改用 Gitee 镜像安装 acme.sh……"
        rm -rf /tmp/acme.sh-src /tmp/acme.sh-master /tmp/acme.sh.tar.gz
        if command -v git >/dev/null 2>&1; then
            git clone --depth 1 https://gitee.com/neilpang/acme.sh.git /tmp/acme.sh-src >/dev/null 2>&1 && \
            (cd /tmp/acme.sh-src && ./acme.sh --install -m "$Aemail") >/dev/null 2>&1 || true
        fi
        if [[ ! -x "$ACME" ]]; then
            wget -O /tmp/acme.sh.tar.gz https://gitee.com/neilpang/acme.sh/repository/archive/master.tar.gz >/dev/null 2>&1 && \
            tar -xzf /tmp/acme.sh.tar.gz -C /tmp >/dev/null 2>&1 && \
            (cd /tmp/acme.sh-master && ./acme.sh --install -m "$Aemail") >/dev/null 2>&1 || true
        fi
    fi

    if [[ ! -x "$ACME" ]]; then
        red "acme.sh 安装失败"
        yellow "请检查 VPS 网络，或手动执行："
        yellow "git clone https://gitee.com/neilpang/acme.sh.git"
        yellow "cd acme.sh && ./acme.sh --install -m 你的邮箱"
        exit 1
    fi

    green "acme.sh 安装完成"
}

install_cert_domain(){
    local domain="$1"
    mkdir -p "$CERT_DIR"

    bash "$ACME" --install-cert -d "$domain" \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" --ecc
}

issue_aliyun(){
    ensure_acme

    echo
    yellow "请输入域名："
    yellow "单域名示例：example.com"
    yellow "泛域名示例：*.example.com"
    read -r ym

    ym="${ym// /}"

    if [[ -z "$ym" ]]; then
        red "域名不能为空"
        return 1
    fi

    echo
    yellow "请输入阿里云 AccessKey ID（Ali_Key）："
    read -r AliKey

    yellow "请输入阿里云 AccessKey Secret（Ali_Secret）："
    read -r AliSecret

    if [[ -z "$AliKey" || -z "$AliSecret" ]]; then
        red "阿里云 Key 不能为空"
        return 1
    fi

    export Ali_Key="$AliKey"
    export Ali_Secret="$AliSecret"

    green "开始通过阿里云 DNS API 申请证书：$ym"

    if ! bash "$ACME" --issue --dns dns_ali -d "$ym" -k ec-384 --server letsencrypt; then
        red "证书申请失败"
        yellow "请检查："
        yellow "1、域名是否已托管在阿里云云解析"
        yellow "2、Ali_Key / Ali_Secret 是否正确"
        yellow "3、阿里云 RAM 是否具备 DNS 解析权限"
        yellow "4、泛域名请输入 *.example.com 格式"
        return 1
    fi

    if install_cert_domain "$ym"; then
        green "证书申请并安装成功"
        green "证书 crt：$CERT_FILE"
        green "私钥 key：$KEY_FILE"
    else
        red "证书已申请，但安装到 /etc/nginx 失败"
        return 1
    fi
}

list_cert(){
    if [[ ! -x "$ACME" ]]; then
        red "未安装 acme.sh"
        return 1
    fi

    green "当前证书列表："
    bash "$ACME" --list
}

renew_cert(){
    if [[ ! -x "$ACME" ]]; then
        red "未安装 acme.sh"
        return 1
    fi

    green "开始一键续签证书…………"
    if ! bash "$ACME" --cron -f; then
        red "续签失败，请查看上方输出"
        return 1
    fi

    local d
    d=$(bash "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | tail -1)

    if [[ -n "$d" && "$d" != "Main_Domain" ]]; then
        install_cert_domain "$d" >/dev/null 2>&1 || true
    fi

    green "续签完成，当前证书列表："
    bash "$ACME" --list
}

uninstall_all(){
    if [[ -x "$ACME" ]]; then
        bash "$ACME" --uninstall >/dev/null 2>&1 || true
    fi

    rm -f "$CERT_FILE" "$KEY_FILE"
    rm -rf "$HOME/.acme.sh"
    sed -i '/acme.sh.env/d' "$HOME/.bashrc" 2>/dev/null || true

    green "acme.sh 与证书已卸载"
}

install_deps

while true; do
    clear
    green "======================================================="
    green "        Acme 阿里云 DNS API 精简版 Debian/Ubuntu"
    green "======================================================="
    yellow "证书安装路径："
    yellow "crt：$CERT_FILE"
    yellow "key：$KEY_FILE"
    echo
    green "1. 阿里云 DNS API 申请/安装证书"
    green "2. 查询已申请证书"
    green "3. 一键续签证书"
    green "4. 卸载 acme.sh 与证书"
    green "0. 退出"
    echo
    yellow "请输入数字："
    read -r NumberInput

    case "$NumberInput" in
        1) issue_aliyun ;;
        2) list_cert ;;
        3) renew_cert ;;
        4) uninstall_all ;;
        0) exit 0 ;;
        *) red "输入有误" ;;
    esac

    echo
    yellow "按回车返回主菜单……"
    read -r
done