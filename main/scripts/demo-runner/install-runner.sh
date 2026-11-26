#!/bin/bash
# durian demo runner 설치 (EC2, Amazon Linux 2023). 초안 - 승인 전 실행 금지.
# 사전: SSM SecureString 3개를 콘솔에서 직접 입력 (값은 코드 · 채팅에 두지 않음)
#   /durian/demo-runner/token       러너 접속 토큰
#   /durian/demo-runner/ssh-key     kolla-b forced-command 계정 개인키
#   /durian/tailscale/aws-demo-runner   Tailscale 인증키 (1회용 · ephemeral · tag:durian-demo-runner)
set -euo pipefail
umask 077
REGION="${REGION:-ap-northeast-2}"; PFX="${SSM_PREFIX:-/durian}"
TARGET="${RUNNER_SSH_TARGET:?예: durian-demo@100.x.x.x (kolla-b 호스트 Tailscale 주소)}"
PORT="${RUNNER_PORT:-8088}"
ssm_get(){ aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption --query Parameter.Value --output text; }

# 1) 필요한 도구 확인, tailscale 설치 (설치 승인 필요, 공식 스크립트가 Amazon Linux 지원)
command -v aws >/dev/null || { echo "aws cli 없음 (Amazon Linux 2023은 기본 포함)"; exit 1; }
command -v ssh >/dev/null || { echo "ssh 클라이언트 없음 (dnf install openssh-clients 는 추가 승인 필요)"; exit 1; }
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

# 2) 전용 계정과 파일 (root 소유 설정, 서비스 계정은 읽기만)
id demo-runner >/dev/null 2>&1 || useradd --system --home /var/lib/demo-runner --shell /usr/sbin/nologin demo-runner
install -d -m 0750 -o root -g demo-runner /etc/demo-runner
install -d -m 0755 /opt/demo-runner
ssm_get "$PFX/demo-runner/token"   > /etc/demo-runner/token
ssm_get "$PFX/demo-runner/ssh-key" > /etc/demo-runner/id_ed25519
chown root:demo-runner /etc/demo-runner/token /etc/demo-runner/id_ed25519
chmod 0640 /etc/demo-runner/token; chmod 0640 /etc/demo-runner/id_ed25519
# runner.py 는 이 스크립트와 같은 디렉터리에 있어야 함
install -m 0755 "$(dirname "$0")/runner.py" /opt/demo-runner/runner.py

# 3) Tailscale 가입 (태그 기기, 서브넷 라우트 없음)
tailscale status >/dev/null 2>&1 || tailscale up --authkey="$(ssm_get "$PFX/tailscale/aws-demo-runner")" \
  --advertise-tags=tag:durian-demo-runner --hostname=durian-demo-runner
TSIP="$(tailscale ip -4 | head -1)"

# 4) known_hosts (kolla-b 호스트키는 사람이 확인한 값을 미리 넣어야 함: StrictHostKeyChecking=yes)
install -d -m 0700 -o demo-runner /var/lib/demo-runner/.ssh
[ -f /var/lib/demo-runner/.ssh/known_hosts ] || echo "# 여기에 kolla-b 호스트키 한 줄을 사람이 확인 후 추가" > /var/lib/demo-runner/.ssh/known_hosts
chown -R demo-runner /var/lib/demo-runner/.ssh

# 5) systemd (Tailscale 주소에만 바인딩, 최소 권한)
cat > /etc/systemd/system/demo-runner.service <<UNIT
[Unit]
Description=durian demo runner
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
User=demo-runner
Environment=RUNNER_BIND=${TSIP}
Environment=RUNNER_PORT=${PORT}
Environment=RUNNER_TOKEN_FILE=/etc/demo-runner/token
Environment=RUNNER_SSH_TARGET=${TARGET}
Environment=RUNNER_SSH_KEY=/etc/demo-runner/id_ed25519
ExecStart=/usr/bin/python3 /opt/demo-runner/runner.py
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/demo-runner
UNIT
systemctl daemon-reload
echo "설치 완료. 시작: systemctl enable --now demo-runner  (kolla-b known_hosts 등록 후)"
echo "롤백: systemctl disable --now demo-runner; rm -rf /opt/demo-runner /etc/demo-runner /etc/systemd/system/demo-runner.service; tailscale logout"
