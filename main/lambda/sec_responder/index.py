"""durian-sec-responder: 보안 자동 대응 Lambda (보안 기준서 LOG-05·06). 담당: 보안(송윤지)

1) 보안그룹 인바운드에 0.0.0.0/0·::/0 이 열리면 그 규칙만 규칙 ID 단위로 지우고 Discord 보안 채널에 알림
   입력: EventBridge 'AWS API Call via CloudTrail' (AuthorizeSecurityGroupIngress, ModifySecurityGroupRules)
   이벤트에서 보안그룹 ID만 꺼내고 그 그룹의 '현재' 규칙을 다시 조회해서 판단 (같은 이벤트가 두 번 와도 결과 같음)
2) GuardDuty 탐지(심각도 4 이상)는 알림만
모드: MODE=notify(알림만, 기본) | revoke(실제 삭제). 예외: EXCEPTIONS (코드·Terraform으로만 바뀜, 태그는 근거로 안 씀)
웹훅 URL은 코드·환경 변수에 두지 않고 SSM SecureString(WEBHOOK_PARAM)에서 읽음 (SEC-01·05)
"""
import json
import os
import urllib.request

import boto3

PUBLIC = {'0.0.0.0/0', '::/0'}


def _exceptions():
    # 예: '{"sg-0abc": [80, 443]}'  → 그 보안그룹의 해당 포트만 공개 허용 (EX-01)
    return {k: set(v) for k, v in json.loads(os.environ.get('EXCEPTIONS', '{}')).items()}


def group_ids(detail):
    rp = detail.get('requestParameters') or {}
    ids = set()
    if 'groupId' in rp:  # AuthorizeSecurityGroupIngress
        ids.add(rp['groupId'])
    m = rp.get('ModifySecurityGroupRulesRequest') or {}
    if 'GroupId' in m:  # ModifySecurityGroupRules
        ids.add(m['GroupId'])
    for it in ((detail.get('responseElements') or {}).get('securityGroupRuleSet') or {}).get('items', []):
        ids.add(it['groupId'])
    return sorted(ids)


def public_rules(ec2, gid):
    rules = ec2.describe_security_group_rules(Filters=[{'Name': 'group-id', 'Values': [gid]}])['SecurityGroupRules']
    out = []
    for r in rules:
        if r.get('IsEgress'):
            continue
        if r.get('CidrIpv4') in PUBLIC or r.get('CidrIpv6') in PUBLIC:
            out.append(r)
    return out


def excepted(rule, exc):
    allowed = exc.get(rule['GroupId'])
    if not allowed:
        return False
    # 포트 범위 전체가 허용 포트 안에 있을 때만 예외 (0-65535 같은 넓은 범위는 예외가 아님)
    lo, hi = rule.get('FromPort', -1), rule.get('ToPort', -1)
    return rule.get('IpProtocol') == 'tcp' and lo == hi and lo in allowed


_webhook = None


def _discord(msg):
    """Discord 보안 채널로 보냄. 실패해도 대응은 멈추지 않고 로그에 남김 (Lambda 오류 경보로 확인)"""
    global _webhook
    print(json.dumps({'alert': msg}, ensure_ascii=False))  # CloudWatch Logs (Grafana 패널이 이 줄을 셈)
    name = os.environ.get('WEBHOOK_PARAM')
    if not name:
        return
    try:
        if _webhook is None:
            _webhook = boto3.client('ssm').get_parameter(Name=name, WithDecryption=True)['Parameter']['Value']
        text = '[보안] ' + ' | '.join(f'{k}={v}' for k, v in msg.items())
        req = urllib.request.Request(_webhook, data=json.dumps({'content': text[:1900]}).encode(),
                                     headers={'Content-Type': 'application/json', 'User-Agent': 'durian-sec-responder'})
        urllib.request.urlopen(req, timeout=5).read()
    except Exception as e:  # noqa: BLE001 - 알림 실패로 차단까지 실패하면 안 됨
        print(json.dumps({'notify_error': type(e).__name__}))


def guardduty(event, notify):
    d = event.get('detail', {})
    notify({'type': 'guardduty', 'severity': d.get('severity'), 'finding': d.get('type'),
            'resource': (d.get('resource') or {}).get('resourceType'), 'region': d.get('region'), 'id': d.get('id')})
    return {'revoked': []}


def handler(event, context=None, ec2=None, notify=None):
    notify = notify or _discord
    if event.get('source') == 'aws.guardduty':
        return guardduty(event, notify)
    ec2 = ec2 or boto3.client('ec2')
    detail = event.get('detail', {})
    mode = os.environ.get('MODE', 'notify')
    if detail.get('errorCode'):  # 실패한 호출(권한 없음 등)은 규칙이 안 생겼으므로 알림만
        notify({'type': 'failed-call', 'event': detail.get('eventName'), 'error': detail.get('errorCode')})
        return {'revoked': []}
    exc = _exceptions()
    who = (detail.get('userIdentity') or {}).get('arn', 'unknown')
    revoked = []
    for gid in group_ids(detail):
        targets = [r for r in public_rules(ec2, gid) if not excepted(r, exc)]
        if not targets:
            continue
        ids = [r['SecurityGroupRuleId'] for r in targets]
        if mode != 'revoke':  # 알림만 모드: 지우지 않고 무엇이 열렸는지만 알림
            notify({'type': 'public-rule-found', 'group': gid, 'rules': ids, 'by': who,
                    'event': detail.get('eventName'), 'time': detail.get('eventTime')})
            continue
        try:
            ec2.revoke_security_group_ingress(GroupId=gid, SecurityGroupRuleIds=ids)
        except ec2.exceptions.ClientError as e:  # 이미 지워진 규칙 등: 다시 조회해서 남은 것만 판단
            if 'InvalidSecurityGroupRuleId.NotFound' not in str(e):
                raise
        revoked += ids
        notify({'type': 'revoked', 'group': gid, 'rules': ids, 'by': who, 'event': detail.get('eventName'),
                'time': detail.get('eventTime'), 'sourceIP': detail.get('sourceIPAddress')})
    return {'revoked': revoked}
