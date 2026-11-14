#!/bin/bash
# 서비스(backend)를 새 태그로 교체한다. 헬스체크에 실패하면 직전 이미지로 롤백한다.
# 사용: ./deploy-service.sh backend <image-tag>
set -euo pipefail
cd "$(dirname "$0")"

SERVICE="${1:?service (backend)}"
NEW_TAG="${2:?image tag}"

case "$SERVICE" in
  backend)  TAG_VAR=BACKEND_IMAGE_TAG ;;
  *) echo "unknown service: $SERVICE" >&2; exit 2 ;;
esac

./fetch-env.sh
OWNER="$(grep -E '^GHCR_OWNER=' .env | head -1 | cut -d= -f2-)"
IMAGE="ghcr.io/${OWNER}/allbutyou-${SERVICE}"
DC="sudo docker compose"

wait_healthy() {
  local cid status timeout=150
  cid="$($DC ps -q "$SERVICE")"
  while [ $timeout -gt 0 ]; do
    status="$(sudo docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)"
    echo "health: $status (남은 ${timeout}s)"
    [ "$status" = "healthy" ] && return 0
    [ "$status" = "unhealthy" ] && return 1
    sleep 3; timeout=$((timeout - 3))
  done
  return 1
}

# 1. 롤백용으로 현재 이미지를 previous 로 보관
sudo docker tag "${IMAGE}:latest" "${IMAGE}:previous" 2>/dev/null || true

# 2. 새 이미지 pull 후 해당 서비스만 교체
export "$TAG_VAR=$NEW_TAG"
$DC pull "$SERVICE"
$DC up -d --no-deps "$SERVICE"

# 3. 헬스체크. 실패하면 롤백
if ! wait_healthy; then
  echo "헬스체크 실패. 로그:" >&2
  $DC logs --tail=100 "$SERVICE" >&2 || true
  if sudo docker image inspect "${IMAGE}:previous" >/dev/null 2>&1; then
    echo "previous 로 롤백한다" >&2
    export "$TAG_VAR=previous"
    $DC up -d --no-deps --force-recreate "$SERVICE"
  fi
  exit 1
fi

# 4. 성공: 이 태그를 latest 로 올려 이후 `compose up -d` 가 같은 이미지를 쓰게 한다
sudo docker tag "${IMAGE}:${NEW_TAG}" "${IMAGE}:latest"
echo "${SERVICE} 배포 완료 (${NEW_TAG})"

# 5. 정리
sudo docker image prune -f >/dev/null
sudo docker images "$IMAGE" --format '{{.Tag}}' \
  | grep -v -E "^(${NEW_TAG}|latest|previous)$" \
  | xargs -r -I{} sudo docker rmi "${IMAGE}:{}" 2>/dev/null || true
