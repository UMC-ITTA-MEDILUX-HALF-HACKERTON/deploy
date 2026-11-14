#!/bin/bash
# 최초 1회: Let's Encrypt 인증서 발급. DNS 의 A 레코드가 이 서버를 가리킨 뒤에 실행한다.
# 사용: ./init-cert.sh you@example.com
set -euo pipefail
cd "$(dirname "$0")"

EMAIL="${1:?인증서 만료 알림을 받을 이메일}"
API_HOST="api.allbutyou.devnoco.com"

./fetch-env.sh

# 1. http-only 설정으로 nginx 만 먼저 띄운다 (백엔드 의존 없이)
export NGINX_CONF=default.http-only.conf
sudo -E docker compose up -d --no-deps --force-recreate nginx

# 2. webroot 방식으로 발급. api 도메인 하나만 발급한다 (FE 는 Vercel)
sudo docker compose run --rm --entrypoint certbot certbot certonly \
  --webroot -w /var/www/certbot \
  -d "$API_HOST" \
  --email "$EMAIL" --agree-tos --no-eff-email --non-interactive

# 3. 실제 설정으로 전환 (NGINX_CONF 를 비워서 default.conf 사용)
unset NGINX_CONF
sudo docker compose up -d
sudo docker compose up -d --force-recreate nginx
echo "인증서 발급 완료: https://${API_HOST}"
