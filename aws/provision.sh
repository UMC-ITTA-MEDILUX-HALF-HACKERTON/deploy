#!/bin/bash
# AWS CLI 로 allbutyou 인프라를 만든다 (Git Bash 에서 실행). 여러 번 돌려도 있는 건 건너뛴다.
#   S3(비밀 버킷) / IAM 역할 / 보안그룹 / 키페어 / EC2 / Elastic IP  (Route 53 은 USE_ROUTE53=1 일 때만)
#
# 사용: ./provision.sh            (env: AWS_PROFILE, AWS_REGION 등으로 조정)
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash 가 /aws/service/... 를 윈도 경로로 바꾸는 것을 막는다
export AWS_PAGER=""

REGION="${AWS_REGION:-ap-southeast-2}"
export AWS_DEFAULT_REGION="$REGION"
NAME="allbutyou"
ROOT_DOMAIN="devnoco.com"
API_HOST="api.allbutyou.devnoco.com"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
VOLUME_GB="${VOLUME_GB:-30}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"      # GitHub Actions 가 SSH 로 들어오므로 기본은 열어둔다. 좁힐 수 있으면 좁힐 것
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${NAME}.pem}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${NAME}-secrets-${ACCOUNT_ID}"
echo "계정 $ACCOUNT_ID / 리전 $REGION / 버킷 $BUCKET"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; cd "$WORK"

# ── 1. S3: .env 보관 (비공개) ─────────────────────────
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  echo "버킷 생성: $BUCKET"
fi

# ── 2. IAM: EC2 가 S3 의 config/ 를 읽고 SSM 접속을 받을 수 있게 ──
ROLE="${NAME}-ec2-role"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  cat > trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document file://trust.json >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  echo "역할 생성: $ROLE"
fi
cat > s3policy.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::${BUCKET}/config/*"}]}
EOF
aws iam put-role-policy --role-name "$ROLE" --policy-name read-config --policy-document file://s3policy.json
if ! aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
  echo "인스턴스 프로파일 전파 대기..."; sleep 15
fi

# ── 3. 네트워크: 기본 VPC + 보안그룹 ───────────────────
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
[ "$VPC_ID" != "None" ] || { echo "기본 VPC 가 없다. 직접 VPC/서브넷을 지정하도록 스크립트를 고쳐야 한다" >&2; exit 1; }
SG_ID="$(aws ec2 describe-security-groups --filters Name=group-name,Values="${NAME}-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [ "$SG_ID" = "None" ]; then
  SG_ID="$(aws ec2 create-security-group --group-name "${NAME}-sg" --description "${NAME} web" \
    --vpc-id "$VPC_ID" --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${SSH_CIDR}}]" >/dev/null
  echo "보안그룹 생성: $SG_ID"
fi

# ── 4. 키페어 ─────────────────────────────────────────
if ! aws ec2 describe-key-pairs --key-names "$NAME" >/dev/null 2>&1; then
  mkdir -p "$(dirname "$KEY_FILE")"
  aws ec2 create-key-pair --key-name "$NAME" --query KeyMaterial --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE" || true
  echo "키페어 저장: $KEY_FILE  (GitHub Secret SSH_KEY 에 이 파일 내용을 넣는다)"
fi

# ── 5. EC2 ───────────────────────────────────────────
INSTANCE_ID="$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="$NAME" Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
if [ "$INSTANCE_ID" = "None" ]; then
  AMI_ID="$(aws ssm get-parameter \
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)"
  cat > userdata.sh <<'EOF'
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y unzip curl ca-certificates
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
mkdir -p /home/ubuntu/allbutyou/deploy
chown -R ubuntu:ubuntu /home/ubuntu/allbutyou
echo done > /var/log/allbutyou-bootstrap.done
EOF
  INSTANCE_ID="$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$NAME" --security-group-ids "$SG_ID" \
    --iam-instance-profile Name="$ROLE" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${VOLUME_GB},VolumeType=gp3}" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2 \
    --user-data file://userdata.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
    --query 'Instances[0].InstanceId' --output text)"
  echo "인스턴스 생성: $INSTANCE_ID"
fi
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# ── 6. Elastic IP ────────────────────────────────────
EIP="$(aws ec2 describe-addresses --filters Name=tag:Name,Values="$NAME" \
  --query 'Addresses[0].PublicIp' --output text)"
if [ "$EIP" = "None" ]; then
  ALLOC="$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}}]" \
    --query AllocationId --output text)"
  aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC" >/dev/null
  EIP="$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].PublicIp' --output text)"
  echo "Elastic IP: $EIP"
fi

# ── 7. DNS ───────────────────────────────────────────
# 기본은 건드리지 않는다. 도메인을 Cloudflare 등 외부에서 관리하면 A 레코드를 그쪽에 직접 추가한다.
# Route 53 을 쓰려면 USE_ROUTE53=1 (호스티드 존이 없으면 만들고 네임서버를 출력한다)
if [ "${USE_ROUTE53:-0}" = "1" ]; then
  ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$ROOT_DOMAIN"     --query "HostedZones[?Name=='${ROOT_DOMAIN}.'].Id | [0]" --output text | sed 's#/hostedzone/##')"
  if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    ZONE_ID="$(aws route53 create-hosted-zone --name "$ROOT_DOMAIN" --caller-reference "${NAME}-$(date +%s)"       --query 'HostedZone.Id' --output text | sed 's#/hostedzone/##')"
    echo "호스티드 존 생성: $ZONE_ID"
    aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers' --output text
  fi
  cat > records.json <<EOR
{"Changes":[
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"${API_HOST}","Type":"A","TTL":300,"ResourceRecords":[{"Value":"${EIP}"}]}}
]}
EOR
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch file://records.json >/dev/null
  DNS_MSG="Route 53 에 A 레코드 등록 완료"
else
  DNS_MSG="DNS 는 직접 설정: A  ${API_HOST} -> ${EIP}  (Cloudflare 는 Proxy 끔=DNS only)"
fi

cat <<EOF

========== 완료 ==========
EC2        : $INSTANCE_ID ($INSTANCE_TYPE)  /  IP $EIP
DNS        : $DNS_MSG
S3 버킷    : $BUCKET   (config/.env 를 올려야 한다. deploy/aws/env.example 참고)
SSH        : ssh -i $KEY_FILE ubuntu@$EIP
부트스트랩 : 서버에 docker 가 깔릴 때까지 2~3분 (ls /var/log/allbutyou-bootstrap.done)

GitHub Secrets (조직 레벨 권장): SSH_HOST=$EIP  SSH_USERNAME=ubuntu  SSH_KEY=<$KEY_FILE 내용>
EOF
