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
CUR_TAG="$NEW_TAG"
# sudo 는 환경변수를 지운다. 태그 변수를 명시적으로 넘겨야 compose 가 그 태그를 쓴다
dc() { sudo env "$TAG_VAR=$CUR_TAG" docker compose "$@"; }

wait_healthy() {
  local cid status timeout=150
  cid="$(dc ps -q "$SERVICE")"
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
# --no-deps 로 교체하므로 의존 서비스(mysql)는 따로 보장한다. 이미 떠 있으면 아무 일도 하지 않는다
dc up -d --wait mysql
dc pull "$SERVICE"
dc up -d --no-deps "$SERVICE"

# 3. 헬스체크. 실패하면 롤백
if ! wait_healthy; then
  echo "헬스체크 실패. 로그:" >&2
  dc logs --tail=100 "$SERVICE" >&2 || true
  if sudo docker image inspect "${IMAGE}:previous" >/dev/null 2>&1; then
    echo "previous 로 롤백한다" >&2
    CUR_TAG=previous
    dc up -d --no-deps --force-recreate "$SERVICE"
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
