# DURIAN PR #9 / PR #10 통합 검토

기준일: 2026-11-21
브랜치: review/aws-k3s-team-integration-20261120
기준: 보안 기준서 V.1 / 허용 포트 목록 V.1

## 1. 아키텍처 변경

기존: 외부 MariaDB 기반 K3s HA 설계

현재:
- Cluster A: Master A + Worker A, AZ 2a
- Cluster C: Master C + Worker C, AZ 2c
- Master별 독립 SQLite 및 K3s Token
- Worker A/C별 독립 ASG
- 각 클러스터의 SSM Parameter 경로 분리

두 Master가 하나의 HA Control Plane을 구성하지 않는다.

## 2. IAM / SSM

- master-a/c: 소속 클러스터 토큰 및 IP 조회/저장
- worker-a/c: 소속 클러스터 토큰 및 IP 조회
- Master Tailscale: /durian/tailscale/aws-master
- Worker Tailscale: /durian/tailscale/aws-worker
- EC2 Instance Profile 자동 연결 코드 구현
- 실제 신규 EC2 배포 및 IAM 동작 미검증

## 3. Bootstrap 통합

- PR #10 install.sh를 User Data 진입점으로 사용
- ROLE=master/worker, CLUSTER=a/c 전달
- SSM 저장 실패 시 오류 반환
- Kubeconfig 모드 600 유지
- K3s Secrets 암호화 true 전달
- Tailscale SSH는 TS_SSH=false가 기본
- 실제 설치 및 Worker 조인 테스트 미실시

## 4. 네트워크 및 보안

- Cluster A/C 전용 Master/Worker SG 구성
- K3s API 6443/TCP, Flannel 8472/UDP
- Kubelet 10250/TCP은 소속 클러스터 내부만 허용
- ALB에서 Worker NodePort 30080으로 전달
- NAT EC2 및 Private Subnet 라우팅 코드 준비
- EX-03: 승인된 Egress에 한정하여 Trivy 예외
- EX-09: 구형 Traefik YAML 삭제, 신규 설치 스크립트 사용
- 기존 durian-node SG는 사용 중이므로 변경 보류
- 기존 admin_cidrs는 빈 값 유지, 이전 후 SG 정리 검토
- AWS 인스턴스 관리 접근은 SSM 사용 (NET-04)

## 5. PR #10 후속 커밋

최초 Cherry-pick: c2f7cf2
후속 검토 대상: c6af397

- Tailscale SSH 옵션화: 반영
- Secrets 암호화: 신규 User Data에서 true 전달
- SSM 저장 실패 처리: PR #9 강화 동작 유지
- Kubeconfig 권한: PR #9의 600 유지
- Traefik Helm 설정: 실제 배포 전 확인
- PR #10 중복 병합 여부는 재우님과 협의

## 6. 검증 현황

- Terraform fmt / validate 성공
- Gitleaks, TFLint, Trivy CI 성공
- GitHub CI Plan: 66 add / 0 change / 0 destroy
- 기존 EC2 변경/삭제 없음
- 신규 NAT, K3s, ALB 기본 비활성화

## 7. 남은 작업

- 기존 durian-node SG 이전 및 Egress 보안 검토
- NAT 인터넷 연결 및 비용 검증
- 실제 Master/Worker K3s 설치 및 조인
- SSM Parameter Store 권한 실제 동작
- Tailscale ACL과 OpenStack 내부 API 연결
- Argo CD Application / GitOps Overlay 연결
- ALB 헬스체크와 장애 전환 테스트
- 팀 코드 리뷰 및 보안 예외 승인

Terraform Apply / Merge는 팀 승인 전 실행하지 않는다.