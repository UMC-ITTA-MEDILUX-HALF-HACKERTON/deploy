#!/bin/bash
# 2GB 인스턴스에서 Spring + MySQL + Next 를 같이 돌리면 메모리가 빠듯하다. 2GB 스왑을 만든다 (멱등).
set -euo pipefail

if swapon --show | grep -q /swapfile; then
  echo "swap 이미 있음"
  exit 0
fi

sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo "swap 2G 설정 완료"
