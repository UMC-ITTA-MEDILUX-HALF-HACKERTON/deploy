# allbutyou 배포 (백엔드: AWS EC2 1대 + docker compose / 프론트: Vercel)

```
Vercel ── allbutyou.devnoco.com (Next.js)
                │  NEXT_PUBLIC_API_BASE_URL=https://api.allbutyou.devnoco.com
Cloudflare DNS ─ api.allbutyou.devnoco.com → EIP → EC2 (ap-southeast-2, t3.small)
                                  nginx(80/443, certbot) ─┬→ backend (Spring :8080, /ws)
                                                          └→ mysql 8 (볼륨)
```

- 이미지: GHCR `ghcr.io/<org 소문자>/allbutyou-backend` (태그: 커밋 SHA + latest)
- 비밀값: S3 `allbutyou-secrets-<계정ID>/config/.env` (EC2 인스턴스 프로파일로 읽는다)
- 배포: backend repo Actions 가 이미지 빌드 → SSH → `deploy-service.sh` (헬스체크 실패 시 previous 로 롤백)
- DNS 는 Cloudflare 에서 관리한다 (Route 53 미사용, Proxy 는 꺼야 인증서 발급이 된다)

## 최초 세팅 순서

1. `aws login --region ap-southeast-2` 후 `bash deploy/aws/provision.sh`
2. `deploy/aws/env.example` 을 채워 S3 `config/.env` 로 업로드 (provision 직후 임의 비밀번호로 한 번 올려둔다)
3. Cloudflare: A `api.allbutyou` → EIP (DNS only). FE 도메인은 Vercel 안내대로 설정
4. GitHub Secrets (backend repo 또는 org): `SSH_HOST`, `SSH_USERNAME`(ubuntu), `SSH_KEY`
5. backend repo main 에 푸시 → 이미지 빌드 + 배포. GHCR 패키지를 public 으로 바꾸거나 `.env` 에 GHCR_USER/TOKEN 설정
6. 서버에서 `./init-cert.sh 이메일` — 인증서 발급 + HTTPS 전환 (nginx 는 `--no-deps` 로 먼저 띄워 발급)

## 백엔드/프론트에서 맞출 것

- `CorsConfig` 의 `allowedOriginPatterns` 에 `https://allbutyou.devnoco.com` (+ Vercel 프리뷰가 필요하면 `https://*.vercel.app`) 추가
- Vercel 환경변수: `NEXT_PUBLIC_API_BASE_URL=https://api.allbutyou.devnoco.com`, `NEXT_PUBLIC_SITE_URL`
- prod 설정은 compose 가 `SPRING_DATASOURCE_*` 환경변수로 주입한다. `application-prod.yml` 불필요
