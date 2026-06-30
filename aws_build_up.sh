#!/bin/bash

# ==============================================================================
# AWS GPU 기반 코딩 에이전트 인프라 구축 스크립트 (Auto Scaling & ALB 연동 버전)
# ==============================================================================
# 주의: 실행 전에 아래 변수를 실제 사용 환경에 맞게 입력해 주세요.

# [사용자 설정 변수]
AWS_ACCOUNT_ID="YOUR_AWS_ACCOUNT_ID"          # AWS 계정 ID (예: 123456789012)
VPC_ID="YOUR_VPC_ID"                          # 대상 VPC ID (예: vpc-xxxxxxxx)
SUBNET_ID_1="YOUR_SUBNET_ID_1"                # 대상 서브넷 ID 1 (가용영역 A)
SUBNET_ID_2="YOUR_SUBNET_ID_2"                # 대상 서브넷 ID 2 (가용영역 B, ALB용 필수)
SECURITY_GROUP_ID="YOUR_SECURITY_GROUP_ID"    # 보안 그룹 ID (예: sg-xxxxxxxx)
KEY_NAME="YOUR_KEY_PAIR_NAME"                # EC2 키페어 이름 (예: my-key-pair)
REGION="ap-northeast-2"                      # 대상 리전 (기본값: 서울 리전)
INSTANCE_TYPE="g6.12xlarge"                  # 인스턴스 타입 (기본값: 4x L4 GPU)

# [데이터 유실 방지 아키텍처 설정]
S3_MODEL_URI="s3://YOUR_S3_BUCKET_NAME/models" # 재학습 모델 가중치 백업용 S3 URI (선택 사항)
IAM_INSTANCE_PROFILE_NAME="YOUR_IAM_INSTANCE_PROFILE_NAME" # IAM 인스턴스 프로파일 이름 (미입력 시 기본값 CodingAgentEC2InstanceProfile 생성 및 설정)

# ==============================================================================

# 필수 입력 값 체크
if [[ "$AWS_ACCOUNT_ID" == *"YOUR_"* || "$VPC_ID" == *"YOUR_"* || "$SUBNET_ID_1" == *"YOUR_"* || "$SUBNET_ID_2" == *"YOUR_"* || "$SECURITY_GROUP_ID" == *"YOUR_"* || "$KEY_NAME" == *"YOUR_"* ]]; then
    echo "⚠️ 에러: 스크립트 상단의 '사용자 설정 변수' 항목들을 실제 본인의 AWS 정보로 채워주신 후 실행하세요."
    exit 1
fi

# IAM Instance Profile 동적 생성 및 설정
if [[ "$IAM_INSTANCE_PROFILE_NAME" == *"YOUR_IAM_INSTANCE_PROFILE_NAME"* ]]; then
    # 사용자가 이름을 수정하지 않은 경우 기본값으로 전환하여 자동 생성 실행
    IAM_INSTANCE_PROFILE_NAME="CodingAgentEC2InstanceProfile"
fi

if ! aws iam get-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
    echo "🚀 [0/7] IAM Role & Instance Profile ($IAM_INSTANCE_PROFILE_NAME) 생성 및 설정 중..."
    
    # EC2 신뢰 관계 정책 문서 임시 작성
    cat << 'EOF' > ec2-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    
    # IAM 역할 생성
    aws iam create-role \
        --role-name "CodingAgentEC2Role" \
        --assume-role-policy-document file://ec2-trust-policy.json > /dev/null
        
    # S3 Full Access & SSM Managed 정책 연결 (S3 복사 기능 및 AWS Session Manager 보안 접속 활성화)
    aws iam attach-role-policy \
        --role-name "CodingAgentEC2Role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
        
    aws iam attach-role-policy \
        --role-name "CodingAgentEC2Role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        
    # 인스턴스 프로파일 생성
    aws iam create-instance-profile \
        --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" > /dev/null
        
    # 인스턴스 프로파일에 역할 추가
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
        --role-name "CodingAgentEC2Role" > /dev/null
        
    rm -f ec2-trust-policy.json
    echo "✅ IAM Role (CodingAgentEC2Role) 및 Instance Profile ($IAM_INSTANCE_PROFILE_NAME) 생성 완료!"
    
    # IAM 전파 대기 (EC2 시작 템플릿 즉시 매칭 시 프로파일 미인식 에러 예방)
    echo "⏳ IAM 역할 변경사항 전파 대기 중 (15초)..."
    sleep 15
else
    echo "ℹ️ IAM Instance Profile ($IAM_INSTANCE_PROFILE_NAME)이 이미 존재합니다. 생성을 건너뜁니다."
fi

echo "🚀 [1/7] 최신 Ubuntu 22.04 LTS AMI ID 조회 중..."
# SSM Parameter Store를 사용해 공식 Ubuntu 22.04 LTS(x86_64) AMI ID 자동 조회
AMI_ID=$(aws ssm get-parameters \
    --region "$REGION" \
    --names /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp/ami-id \
    --query "Parameters[0].Value" \
    --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
    echo "❌ AMI ID 조회 실패. AWS CLI 설정 및 네트워크 상태를 확인하세요."
    exit 1
fi
echo "👉 최신 Ubuntu 22.04 AMI ID: $AMI_ID"


echo "📝 [2/7] EC2 가동용 User Data 생성 및 Base64 인코딩 중..."
# 인스턴스 부팅 후 NVIDIA 드라이버, 도커, NVMe RAID0, vLLM 듀얼 서빙을 설치할 스크립트 작성
cat << 'EOF' > user_data_bootstrap.sh
#!/bin/bash
# 사용자 데이터 실행 로그 설정
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "========================================="
echo "STDOUT/STDERR LOGGING INITIATED"
echo "========================================="

# 1. RAID0 local NVMe SSD 구성
echo "=== [Bootstrap] 1. RAID0 로컬 NVMe SSD 구성 ==="
apt-get update && apt-get install -y mdadm nvme-cli

nvme_drives=""
for d in /dev/nvme[1-9]n1; do
  if [ -b "$d" ] && [ "$d" != "/dev/nvme0n1" ]; then
    nvme_drives="$nvme_drives $d"
  fi
done

if [ -n "$nvme_drives" ]; then
  drive_count=$(echo $nvme_drives | wc -w)
  echo "Found $drive_count NVMe instance store drives: $nvme_drives"
  for d in $nvme_drives; do
    mdadm --zero-superblock $d || true
  done
  mdadm --create --verbose /dev/md0 --level=0 --name=local-nvme-raid0 --raid-devices=$drive_count $nvme_drives --run
  mkfs.ext4 -F /dev/md0
  mkdir -p /mnt/local-nvme
  mount /dev/md0 /mnt/local-nvme
  chmod 777 /mnt/local-nvme
  echo "/dev/md0 /mnt/local-nvme ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
  echo "RAID0 NVMe storage mounted on /mnt/local-nvme successfully."
else
  echo "No local NVMe SSDs found. Using fallback path."
  mkdir -p /mnt/local-nvme
  chmod 777 /mnt/local-nvme
fi

# 2. NVIDIA GPU Driver 설치
echo "=== [Bootstrap] 2. NVIDIA GPU Driver 설치 ==="
export DEBIAN_FRONTEND=noninteractive
apt-get install -y ubuntu-drivers-common
ubuntu-drivers install --gpgpu

# 3. Docker 및 NVIDIA Container Toolkit 설치
echo "=== [Bootstrap] 3. Docker 및 Container Toolkit 설치 ==="
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit

# Docker 환경에 NVIDIA Container Toolkit 반영 및 재시작
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# 4. S3에서 학습 가중치 연동 및 vLLM 서버 기동
echo "=== [Bootstrap] 4. S3에서 학습 가중치 연동 및 vLLM 서버 기동 ==="
mkdir -p /mnt/local-nvme/models
chmod 777 /mnt/local-nvme/models

# 드라이버 바인딩 시간 대기
sleep 15

# AWS CLI 설치 (S3 가중치 복사 용도)
echo "Installing AWS CLI for S3 integration..."
apt-get install -y awscli

# S3 가중치 다운로드 설정
S3_URI="PLACEHOLDER_S3_MODEL_URI"

if [[ "$S3_URI" != *"YOUR_S3_BUCKET_NAME"* && -n "$S3_URI" ]]; then
  echo "Checking S3 bucket: $S3_URI"
  # S3 bucket 동기화
  mkdir -p /mnt/local-nvme/models/custom-model
  aws s3 sync "$S3_URI" /mnt/local-nvme/models/custom-model || true
  
  if [ "$(ls -A /mnt/local-nvme/models/custom-model 2>/dev/null)" ]; then
    echo "Custom model weights downloaded successfully from S3."
  else
    echo "S3 bucket is empty or download failed. Using default HuggingFace models."
  fi
else
  echo "S3_MODEL_URI is not set. Skipping S3 download."
fi

# 로컬 커스텀 모델 가중치가 존재하는 경우 우선 구동하고, 없으면 허깅페이스 Qwen 오리지널 모델을 구동합니다.
MODEL_PATH="Qwen/Qwen2.5-Coder-32B-Instruct"
if [ "$(ls -A /mnt/local-nvme/models/custom-model 2>/dev/null)" ]; then
  MODEL_PATH="/root/.cache/huggingface/custom-model"
  echo "Using custom fine-tuned model weights from S3: $MODEL_PATH"
fi

# GPU 4개 전체를 사용하여 Qwen2.5-Coder-32B-Instruct 또는 커스텀 모델 기동 (Port 8000, TP=4)
docker run -d --name vllm-qwen \
  --restart always \
  --gpus all \
  -v /mnt/local-nvme/models:/root/.cache/huggingface \
  -p 8000:8000 \
  --ipc=host \
  vllm/vllm-openai:latest \
  --model "$MODEL_PATH" \
  --tensor-parallel-size 4 \
  --port 8000 \
  --max-model-len 16384 \
  --gpu-memory-utilization 0.90

# [Phase 2 전환 가이드 주석]
# Qwen Coder 검증이 종료되고 DeepSeek R1 단계로 넘어갈 때 아래 명령을 실행합니다.
# (이 부트스트랩 스크립트는 최초 기동 시 Qwen 혹은 S3 커스텀 모델을 우선 가동하도록 설정되어 있습니다.)
#
# docker stop vllm-qwen && docker rm vllm-qwen
# docker run -d --name vllm-deepseek \
#   --restart always \
#   --gpus all \
#   -v /mnt/local-nvme/models:/root/.cache/huggingface \
#   -p 8001:8001 \
#   --ipc=host \
#   vllm/vllm-openai:latest \
#   --model DeepSeek/DeepSeek-R1-Distill-Qwen-32B \
#   --tensor-parallel-size 4 \
#   --port 8001 \
#   --max-model-len 16384 \
#   --gpu-memory-utilization 0.90

# 5. Nginx 리버스 프록시 설정
echo "=== [Bootstrap] 5. Nginx 라우팅 프록시 설정 ==="
apt-get install -y nginx

cat << 'NGINX_EOF' > /etc/nginx/sites-available/coding-agent
server {
    listen 80;
    listen [::]:80;
    
    # Qwen Coder 라우팅 (/qwen/v1 -> Port 8000/v1)
    location /qwen/ {
        proxy_pass http://localhost:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
    
    # DeepSeek R1 Distill 라우팅 (/deepseek/v1 -> Port 8001/v1)
    location /deepseek/ {
        proxy_pass http://localhost:8001/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
    
    # 헬스체크 랜딩 페이지
    location / {
        return 200 "OK\nvLLM Serving Host is running.\n\nEndpoints:\n- /qwen/v1/chat/completions -> Qwen Coder\n- /deepseek/v1/chat/completions -> DeepSeek R1\n";
        add_header Content-Type text/plain;
    }
}
NGINX_EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/coding-agent /etc/nginx/sites-enabled/coding-agent
systemctl restart nginx

echo "=== [Bootstrap] 모든 설치 및 환경 구축 작업 완료 ==="
EOF

# S3_MODEL_URI 변수를 user-data 파일 내에 반영
sed -i "s|PLACEHOLDER_S3_MODEL_URI|${S3_MODEL_URI}|g" user_data_bootstrap.sh

# 크로스플랫폼 호환성을 보장하는 Python 기반 Base64 인코딩 처리
USER_DATA_BASE64=$(python -c "import base64; print(base64.b64encode(open('user_data_bootstrap.sh','rb').read()).decode())")

# IAM Instance Profile 블록 포함 여부 동적 빌드
IAM_PROFILE_JSON=""
if [[ -n "$IAM_INSTANCE_PROFILE_NAME" && "$IAM_INSTANCE_PROFILE_NAME" != *"YOUR_"* ]]; then
  IAM_PROFILE_JSON="\"IamInstanceProfile\": { \"Name\": \"$IAM_INSTANCE_PROFILE_NAME\" },"
fi

echo "🚀 [3/7] EC2 시작 템플릿(Launch Template) 생성 중..."
# 시작 템플릿 JSON 데이터 임시 작성
cat << EOF > launch_template_data.json
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$SECURITY_GROUP_ID"],
  $IAM_PROFILE_JSON
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/sda1",
      "Ebs": {
        "VolumeSize": 200,
        "VolumeType": "gp3",
        "DeleteOnTermination": true
      }
    }
  ],
  "InstanceMarketOptions": {
    "MarketType": "spot"
  },
  "UserData": "$USER_DATA_BASE64"
}
EOF

# 기존 템플릿 존재 여부 확인 후 삭제 (멱등성 확보)
aws ec2 delete-launch-template \
    --region "$REGION" \
    --launch-template-name "CodingAgentLaunchTemplate" 2>/dev/null || true

# 시작 템플릿 생성 실행
aws ec2 create-launch-template \
    --region "$REGION" \
    --launch-template-name "CodingAgentLaunchTemplate" \
    --launch-template-data file://launch_template_data.json \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Name,Value=CodingAgent-vLLM-LT}]" \
    --output text --query "LaunchTemplate.LaunchTemplateId" > /dev/null


echo "🚀 [4/7] ALB 대상 그룹(Target Group) 생성 중..."
# 기존 동일명 대상 그룹 존재 여부 확인 후 삭제
EXISTING_TG_ARN=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --names "coding-agent-tg" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text 2>/dev/null)

if [ -n "$EXISTING_TG_ARN" ] && [ "$EXISTING_TG_ARN" != "None" ]; then
    echo "  - 기존 대상 그룹 삭제 중..."
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$EXISTING_TG_ARN"
    sleep 5
fi

# 대상 그룹 생성 실행
TG_ARN=$(aws elbv2 create-target-group \
    --region "$REGION" \
    --name "coding-agent-tg" \
    --protocol HTTP \
    --port 80 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)

echo "👉 대상 그룹 ARN: $TG_ARN"


echo "🚀 [5/7] Application Load Balancer(ALB) 생성 중..."
# 기존 동일명 로드밸런서 존재 여부 확인 후 삭제
EXISTING_ALB_ARN=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --names "coding-agent-alb" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text 2>/dev/null)

if [ -n "$EXISTING_ALB_ARN" ] && [ "$EXISTING_ALB_ARN" != "None" ]; then
    echo "  - 기존 로드 밸런서 삭제 중..."
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$EXISTING_ALB_ARN"
    # 삭제 완료 대기
    echo "  - 삭제 대기 중 (30초)..."
    sleep 30
fi

# 로드밸런서 생성 실행
ALB_ARN=$(aws elbv2 create-load-balancer \
    --region "$REGION" \
    --name "coding-agent-alb" \
    --subnets "$SUBNET_ID_1" "$SUBNET_ID_2" \
    --security-groups "$SECURITY_GROUP_ID" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)

DNS_NAME=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --load-balancer-arns "$ALB_ARN" \
    --query "LoadBalancers[0].DNSName" \
    --output text)

echo "👉 로드밸런서 ARN: $ALB_ARN"
echo "👉 접속용 DNS 도메인: http://$DNS_NAME"


echo "🚀 [6/7] ALB HTTP 리스너 생성 및 연동 중..."
# ALB 리스너 생성 실행 (Port 80 요청 시 대상 그룹으로 전달)
aws elbv2 create-listener \
    --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" > /dev/null


echo "🚀 [7/7] Auto Scaling Group(ASG) 생성 중..."
# 기존 동일명 ASG 존재 여부 확인 후 삭제
EXISTING_ASG=$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --auto-scaling-group-names "coding-agent-asg" \
    --query "AutoScalingGroups[0].AutoScalingGroupName" \
    --output text 2>/dev/null)

if [ -n "$EXISTING_ASG" ] && [ "$EXISTING_ASG" != "None" ]; then
    echo "  - 기존 ASG 강제 삭제 중..."
    aws autoscaling update-auto-scaling-group --region "$REGION" --auto-scaling-group-name "coding-agent-asg" --min-size 0 --max-size 0 --desired-capacity 0
    sleep 5
    aws autoscaling delete-auto-scaling-group --region "$REGION" --auto-scaling-group-name "coding-agent-asg" --force-delete
    echo "  - 삭제 완료 대기 중..."
    sleep 15
fi

# Auto Scaling Group 생성 실행 (원하는 인스턴스 수량 1개 설정, 스팟 인스턴스 자동 관리)
aws autoscaling create-auto-scaling-group \
    --region "$REGION" \
    --auto-scaling-group-name "coding-agent-asg" \
    --launch-template "LaunchTemplateName=CodingAgentLaunchTemplate" \
    --min-size 1 \
    --max-size 1 \
    --desired-capacity 1 \
    --target-group-arns "$TG_ARN" \
    --vpc-zone-identifier "$SUBNET_ID_1,$SUBNET_ID_2" \
    --tags "Key=Name,Value=CodingAgent-vLLM-ASG-Member,PropagateAtLaunch=true"

echo "--------------------------------------------------"
echo "✨ 인프라 자동화 구축 완료!"
echo "--------------------------------------------------"
echo "🌐 로드 밸런서 접속 주소: http://$DNS_NAME"
echo "--------------------------------------------------"
echo "💡 가동에는 약 5~10분이 소요됩니다. (스팟 인스턴스 할당 후 NVIDIA 드라이버 빌드 및 Docker 구동 시간)"
echo "💡 스팟 인스턴스가 중단되더라도 Auto Scaling Group에 의해 자동으로 새로운 인스턴스가 생성되고 연결됩니다."
echo "--------------------------------------------------"

# 임시 생성 파일 클린업
rm -f user_data_bootstrap.sh launch_template_data.json
