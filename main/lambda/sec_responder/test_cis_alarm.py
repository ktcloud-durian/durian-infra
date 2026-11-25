"""CIS 경보 알림 테스트 (AWS 호출 없음). 실행: python3 -m unittest -v main/lambda/sec_responder/test_cis_alarm.py"""
import os
import sys
import types
import unittest

sys.modules.setdefault('boto3', types.SimpleNamespace(client=lambda *a, **k: None))
sys.path.insert(0, os.path.dirname(__file__))
import index  # noqa: E402


def alarm_event(name, value='ALARM'):
    return {'source': 'aws.cloudwatch', 'detail-type': 'CloudWatch Alarm State Change', 'time': '2026-11-25T03:00:00Z',
            'detail': {'alarmName': name, 'state': {'value': value, 'reason': 'Threshold Crossed: 1 datapoint [3.0] >= 1.0'}}}


class CisAlarmTest(unittest.TestCase):
    def test_alarm_notifies_only(self):
        msgs = []
        out = index.handler(alarm_event('durian-cis-5.2-ConsoleSigninWithoutMFA'), ec2=object(), notify=msgs.append)
        self.assertEqual(out, {'revoked': []})
        self.assertEqual(msgs[0]['type'], 'cis-alarm')
        self.assertEqual(msgs[0]['alarm'], 'durian-cis-5.2-ConsoleSigninWithoutMFA')
        self.assertEqual(msgs[0]['state'], 'ALARM')

    def test_does_not_touch_security_groups(self):
        class NoEC2:
            def __getattr__(self, _):
                raise AssertionError('경보 알림에서 EC2를 부르면 안 됨')
        msgs = []
        index.handler(alarm_event('durian-cis-5.11-NACLChanges'), ec2=NoEC2(), notify=msgs.append)
        self.assertEqual(len(msgs), 1)

    def test_reason_is_cut(self):
        e = alarm_event('durian-cis-5.1-UnauthorizedAPICalls')
        e['detail']['state']['reason'] = 'x' * 500
        msgs = []
        index.handler(e, ec2=object(), notify=msgs.append)
        self.assertEqual(len(msgs[0]['reason']), 200)


if __name__ == '__main__':
    unittest.main()
