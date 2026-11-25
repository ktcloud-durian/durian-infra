"""sec_responder 오탐·장애 시험 (시연 4 절차서 5장 1~8번). AWS 호출 없음.
실행: python3 -m unittest -v main/lambda/sec_responder/test_edge_cases.py
"""
import json
import os
import sys
import types
import unittest

sys.modules.setdefault('boto3', types.SimpleNamespace(client=lambda *a, **k: None))
sys.path.insert(0, os.path.dirname(__file__))
import index  # noqa: E402


def rule(rid, frm, to, cidr4=None, cidr6=None, proto='tcp', gid='sg-x', egress=False):
    r = {'SecurityGroupRuleId': rid, 'GroupId': gid, 'IsEgress': egress, 'IpProtocol': proto, 'FromPort': frm, 'ToPort': to}
    if cidr4:
        r['CidrIpv4'] = cidr4
    if cidr6:
        r['CidrIpv6'] = cidr6
    return r


class NotFound(Exception):
    pass


class FakeEC2:
    """규칙 목록을 상태로 들고 있어서, 지우면 다음 조회에서 빠짐 (같은 이벤트 두 번 시험용)"""

    class exceptions:
        ClientError = NotFound

    def __init__(self, rules, gone=()):
        self.rules = list(rules)
        self.gone = set(gone)  # 이미 다른 곳에서 지워진 규칙 ID
        self.revoked = []

    def describe_security_group_rules(self, Filters):
        return {'SecurityGroupRules': list(self.rules)}

    def revoke_security_group_ingress(self, GroupId, SecurityGroupRuleIds):
        if self.gone & set(SecurityGroupRuleIds):
            raise NotFound('An error occurred (InvalidSecurityGroupRuleId.NotFound)')
        self.revoked += SecurityGroupRuleIds
        self.rules = [r for r in self.rules if r['SecurityGroupRuleId'] not in SecurityGroupRuleIds]


def event(gid='sg-x', **detail):
    d = {'eventName': 'AuthorizeSecurityGroupIngress', 'requestParameters': {'groupId': gid},
         'userIdentity': {'arn': 'arn:aws:iam::000000000000:user/tester'}, 'eventTime': '2026-11-25T00:00:00Z'}
    d.update(detail)
    return {'source': 'aws.ec2', 'detail': d}


def run(ev, ec2, mode='revoke', exceptions=None):
    os.environ['MODE'] = mode
    os.environ['EXCEPTIONS'] = json.dumps(exceptions or {})
    msgs = []
    out = index.handler(ev, ec2=ec2, notify=msgs.append)
    return out, msgs


class EdgeCases(unittest.TestCase):
    def test_1_alb_exception_80_443_is_left_alone(self):
        ec2 = FakeEC2([rule('sgr-443', 443, 443, '0.0.0.0/0', gid='sg-alb'), rule('sgr-80', 80, 80, '0.0.0.0/0', gid='sg-alb')])
        out, msgs = run(event('sg-alb'), ec2, exceptions={'sg-alb': [80, 443]})
        self.assertEqual(out['revoked'], [])
        self.assertEqual(msgs, [])

    def test_2_wide_port_range_on_exception_group_is_not_excepted(self):
        ec2 = FakeEC2([rule('sgr-all', 0, 65535, '0.0.0.0/0', gid='sg-alb')])
        out, msgs = run(event('sg-alb'), ec2, exceptions={'sg-alb': [80, 443]})
        self.assertEqual(out['revoked'], ['sgr-all'])
        self.assertEqual(msgs[0]['type'], 'revoked')

    def test_3_single_ip_is_not_public(self):
        ec2 = FakeEC2([rule('sgr-ip', 22, 22, '198.51.100.7/32')])
        out, msgs = run(event(), ec2)
        self.assertEqual(out['revoked'], [])
        self.assertEqual(msgs, [])

    def test_4_ipv6_any_is_public(self):
        ec2 = FakeEC2([rule('sgr-v6', 22, 22, cidr6='::/0')])
        out, _ = run(event(), ec2)
        self.assertEqual(out['revoked'], ['sgr-v6'])

    def test_5_same_event_twice_second_is_noop(self):
        ec2 = FakeEC2([rule('sgr-22', 22, 22, '0.0.0.0/0')])
        first, _ = run(event(), ec2)
        second, msgs = run(event(), ec2)
        self.assertEqual(first['revoked'], ['sgr-22'])
        self.assertEqual(second['revoked'], [])
        self.assertEqual(msgs, [])

    def test_6_failed_call_only_notifies(self):
        ec2 = FakeEC2([rule('sgr-22', 22, 22, '0.0.0.0/0')])
        out, msgs = run(event(errorCode='Client.UnauthorizedOperation'), ec2)
        self.assertEqual(out['revoked'], [])
        self.assertEqual(ec2.revoked, [])
        self.assertEqual(msgs[0]['type'], 'failed-call')

    def test_7_already_deleted_rule_does_not_crash(self):
        ec2 = FakeEC2([rule('sgr-22', 22, 22, '0.0.0.0/0')], gone={'sgr-22'})
        out, _ = run(event(), ec2)  # NotFound는 무시하고 끝까지 감
        self.assertIn('sgr-22', out['revoked'])

    def test_7b_other_errors_are_not_swallowed(self):
        class Boom(FakeEC2):
            def revoke_security_group_ingress(self, GroupId, SecurityGroupRuleIds):
                raise NotFound('AccessDenied')
        ec2 = Boom([rule('sgr-22', 22, 22, '0.0.0.0/0')])
        with self.assertRaises(NotFound):  # 권한 문제는 Lambda 오류로 올라가서 오류 경보가 울려야 함
            run(event(), ec2)

    def test_8_webhook_failure_does_not_stop_response(self):
        index._webhook = 'http://127.0.0.1:9/unreachable'  # 닫힌 포트: 전송 실패
        os.environ['WEBHOOK_PARAM'] = '/durian/security/discord-webhook'
        try:
            index._discord({'type': 'test'})  # 예외가 밖으로 나오면 안 됨
        finally:
            index._webhook = None
            os.environ.pop('WEBHOOK_PARAM', None)

    def test_egress_rules_are_ignored(self):
        ec2 = FakeEC2([rule('sgr-out', 443, 443, '0.0.0.0/0', egress=True)])
        out, msgs = run(event(), ec2)
        self.assertEqual(out['revoked'], [])
        self.assertEqual(msgs, [])


if __name__ == '__main__':
    unittest.main()
