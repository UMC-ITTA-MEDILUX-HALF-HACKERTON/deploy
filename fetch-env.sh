#!/bin/bash
# S3 에서 .env 를 받고 GHCR 에 로그인한다. EC2 인스턴스 프로파일로 인증하므로 키가 필요 없다.
set -euo pipefail
cd "$(dirname "$0")"

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-southeast-2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="allbutyou-secrets-${ACCOUNT_ID}"

# BE/FE 배포가 동시에 돌 수 있다. 같은 디렉터리 임시 파일에 받은 뒤 mv(원자적)로 교체한다
tmp="$(mktemp .env.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

aws s3 cp "s3://${BUCKET}/config/.env" "$tmp" --only-show-errors

# 빈 파일로 바꾸면 compose 가 모든 변수를 빈 값으로 읽는다
if [ ! -s "$tmp" ]; then
  echo "fetch-env: 내려받은 .env 가 비어 있어 교체하지 않는다" >&2
  exit 1
fi

if [ -e .env ]; then
  chmod --reference=.env "$tmp"
fi
mv -f "$tmp" .env
echo "fetch-env: .env 갱신 완료"

# private 이미지 pull 용 로그인. compose 는 sudo 로 돌리므로 root 의 docker config 에 저장한다
GHCR_USER="$(grep -E '^GHCR_USER=' .env | head -1 | cut -d= -f2-)"
GHCR_TOKEN="$(grep -E '^GHCR_TOKEN=' .env | head -1 | cut -d= -f2-)"
if [ -n "$GHCR_USER" ] && [ -n "$GHCR_TOKEN" ]; then
  echo "$GHCR_TOKEN" | sudo docker login ghcr.io -u "$GHCR_USER" --password-stdin
  echo "fetch-env: GHCR 로그인 완료"
else
  echo "fetch-env: GHCR_USER/GHCR_TOKEN 이 없어 로그인을 건너뛴다 (public 이미지만 가능)"
fi
