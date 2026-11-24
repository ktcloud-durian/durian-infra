"""sec_responder 단위 테스트 (AWS 호출 없음). 실행: python3 -m unittest -v main/lambda/sec_responder/test_index.py"""
import json
import os
import sys
import types
import unittest

sys.modules.setdefault('boto3', types.SimpleNamespace(client=lambda *a, **k: None))
sys.path.insert(0, os.path.dirname(__file__))
import index  # noqa: E402

RULES = [
    {'SecurityGroupRuleId': 'sgr-443', 'GroupId': 'sg-alb', 'IsEgress': False, 'IpProtocol': 'tcp', 'FromPort': 443, 'ToPort': 443, 'CidrIpv4': '0.0.0.0/0'},
    {'SecurityGroupRuleId': 'sgr-80', 'GroupId': 'sg-alb', 'IsEgress': False, 'IpProtocol': 'tcp', 'FromPort': 80, 'ToPort': 80, 'CidrIpv4': '0.0.0.0/0'},
    {'SecurityGroupRuleId': 'sgr-22', 'GroupId': 'sg-alb', 'IsEgress': False, 'IpProtocol': 'tcp', 'FromPort': 22, 'ToPort': 22, 'CidrIpv4': '0.0.0.0/0'},
    {'SecurityGroupRuleId': 'sgr-priv', 'GroupId': 'sg-alb', 'IsEgress': False, 'IpProtocol': 'tcp', 'FromPort': 9100, 'ToPort': 9100, 'CidrIpv4': '10.20.20.0/24'},
]


class FakeEC2:
    class exceptions:
        ClientError = Exception

    def __init__(self):
        self.revoked = []

    def describe_security_group_rules(self, Filters):
        return {'SecurityGroupRules': RULES}

    def revoke_security_group_ingress(self, GroupId, SecurityGroupRuleIds):
        self.revoked += SecurityGroupRuleIds


def run(event, **env):
    os.environ.update({'MODE': 'notify', 'EXCEPTIONS': '{}'})
    os.environ.update(env)
    msgs, ec2 = [], FakeEC2()
    result = index.handler(event, ec2=ec2, notify=msgs.append)
    return result, msgs, ec2


def api(source, name, **detail):
    d = {'eventName': name, 'userIdentity': {'arn': 'arn:aws:iam::000000000000:user/tester', 'type': 'IAMUser'},
         'sourceIPAddress': '203.0.113.10', 'awsRegion': 'us-east-1', 'eventTime': '2026-11-23T01:00:00Z'}
    d.update(detail)
    return {'source': source, 'detail': d}


class SecurityGroup(unittest.TestCase):
    sg = api('aws.ec2', 'AuthorizeSecurityGroupIngress', requestParameters={'groupId': 'sg-alb'})

    def test_notify_mode_does_not_revoke(self):
        r, msgs, ec2 = run(self.sg)
        self.assertEqual(ec2.revoked, [])
        self.assertEqual(msgs[0]['type'], 'public-rule-found')
        self.assertNotIn('sgr-priv', msgs[0]['rules'])  # 사설 대역은 손대지 않음

    def test_revoke_without_exception_removes_all_public(self):
        _, _, ec2 = run(self.sg, MODE='revoke')
        self.assertEqual(sorted(ec2.revoked), ['sgr-22', 'sgr-443', 'sgr-80'])

    def test_revoke_with_ex01_keeps_alb_80_443(self):
        _, _, ec2 = run(self.sg, MODE='revoke', EXCEPTIONS=json.dumps({'sg-alb': [80, 443]}))
        self.assertEqual(ec2.revoked, ['sgr-22'])


class AuditEvents(unittest.TestCase):
    def test_stop_logging_alerts_high(self):
        r, msgs, ec2 = run(api('aws.cloudtrail', 'StopLogging', requestParameters={'name': 'durian-trail'}))
        self.assertEqual(r, {'revoked': []})
        self.assertEqual(ec2.revoked, [])
        self.assertEqual(msgs[0]['type'], 'cloudtrail-tamper')
        self.assertEqual(msgs[0]['severity'], 'high')
        self.assertEqual(msgs[0]['target'], 'durian-trail')

    def test_admin_policy_attach_is_high(self):
        _, msgs, _ = run(api('aws.iam', 'AttachUserPolicy', requestParameters={
            'userName': 'demo-user', 'policyArn': 'arn:aws:iam::aws:policy/AdministratorAccess'}))
        self.assertEqual(msgs[0]['type'], 'iam-change')
        self.assertEqual(msgs[0]['severity'], 'high')

    def test_denied_access_key_creation_is_reported(self):
        _, msgs, _ = run(api('aws.iam', 'CreateAccessKey', errorCode='AccessDenied',
                             responseElements={'accessKey': {'accessKeyId': 'AKIAEXAMPLE'}}))
        self.assertEqual(msgs[0]['result'], 'AccessDenied')
        self.assertNotIn('AKIAEXAMPLE', json.dumps(msgs[0]))  # 키 ID 같은 응답 내용은 보내지 않음

    def test_root_login(self):
        _, msgs, _ = run({'source': 'aws.signin', 'detail': {
            'eventName': 'ConsoleLogin', 'userIdentity': {'type': 'Root'}, 'responseElements': {'ConsoleLogin': 'Failure'}}})
        self.assertEqual(msgs[0]['type'], 'root-login')
        self.assertEqual(msgs[0]['by'], 'Root')
        self.assertEqual(msgs[0]['result'], 'Failure')
        self.assertEqual(msgs[0]['severity'], 'high')


if __name__ == '__main__':
    unittest.main()
