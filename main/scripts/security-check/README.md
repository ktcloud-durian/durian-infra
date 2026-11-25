# 보안 점검기 (보안 기준서 8.1)

Monitor EC2에서 매일 08:40에 돌아가는 **조회 전용** 점검기예요. 결과는 두 곳에 남아요.

- `/var/lib/durian-check/results/<날짜_시각>/` : 항목마다 PASS·FAIL·ERROR·SKIP 한 줄 JSON (root만 읽기, 60일 보관)
- node_exporter textfile → Prometheus → **Grafana 보안 관제 대시보드** (`durian_check_result` 1=PASS 0=FAIL -1=ERROR)

위반이나 확인 실패가 있으면, 또는 점검기가 2일 넘게 안 돌면 Discord ops-alerts로 경보가 가요.

## 설치 (Monitor EC2, 1회)

```bash
sudo ROLE=monitor ./main/scripts/install.sh            # 모니터링 스택 먼저
sudo bash main/scripts/security-check/setup.sh         # 점검기 + 타이머 + 경보 규칙
sudo vi /etc/durian-check/config.env                   # 관리자·팀원 명단 채우기 (저장소에 올리지 않음)
# OpenStack: reader 자격 증명을 /etc/durian-check/clouds.yaml 에 두고 chmod 600
sudo systemctl start durian-check && sudo journalctl -u durian-check -n 50
```

필요한 AWS 권한은 `main/monitor-ec2.tf`의 `SecurityCheckReadOnly`에 있어요. 조회 권한만 있고, 바꾸는 권한은 없어요.

## 자동으로 보는 항목

| 점검표 | AWS | OpenStack |
|---|---|---|
| 6 빠진 사람·공유 계정 | | OS-A1 |
| 7 관리자 권한 | 7 | OS-A2 |
| 8 만료 없는 키·90일 넘은 키 | 8 | OS-A3 |
| 9 루트 키·콘솔 MFA | 9a·9b | |
| 10 비밀번호 정책 | 10 | |
| 11 배포 역할(OIDC) 신뢰 조건 | 11 | |
| 12 EC2 인스턴스 프로파일 | 12 | |
| 14 인터넷에 열린 규칙 | 14 | OS-R1 |
| 15 VPC 기본 보안그룹 | 15 | |
| 16 콘솔에서 만든 규칙 | (drift.yml) | OS-R2 |
| 17 Floating IP 허용 목록 | | OS-R3 |
| 19 ALB HTTPS | 19 | |
| 20 백업 이미지·스냅샷 공개 | 20 | OS-20 |
| 21 IMDSv2·EBS 암호화·S3 퍼블릭 차단 | 21a·b·c | |
| 22 트레일·ECR·상태 버킷 | 22a·b·c | |
| 25 탐지·자동 대응 | 25a~d | |
| 26 모니터링 스택 노출 | 26a·b·c | |
| reader 쓰기 차단 (IAM-04) | | OS-IAM04 |

직접 확인하는 항목은 1~5(저장소·CI는 PR 검사가 봄), 13(Tailscale 기기), 18(외부 포트 스캔), 23(VM 업데이트), 24(클러스터), 27(ArgoCD)이에요.

## 원칙

- 명령이 실패하면(권한 부족·세션 만료·네트워크) **ERROR**로 남겨요. 빈 결과가 PASS로 보이지 않게 하려는 거예요.
- 결과에는 리소스 ID·이름만 남겨요. 비밀번호·키·토큰은 남기지 않고, 12자리 계정 ID는 `<계정ID>`로 가려요.
- OpenStack 쓰기 차단 시험은 시험용 보안그룹 만들기를 시도해요. 만들어지면 FAIL로 남기고 바로 지워요.

## 직접 실행·시험

```bash
sudo bash /opt/durian-check/run.sh                        # 바로 한 번
OUT=/tmp/t ENDPOINT=http://localhost:5000 bash aws.sh      # moto 서버로 시험 (실제 AWS 안 건드림)
```
