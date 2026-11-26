#!/usr/bin/env python3
"""durian demo runner (EC2, B 사이트 DB 시연 전용) - 초안. 표준 라이브러리만 사용.
요청: POST /api/run/<action>   헤더: X-Token, (위험 단계) X-Confirm, X-Dry-Run(1=모의, 기본 1)
응답: {"ok":bool,"out":str,"verdict":"pass|fail"(선택),"metrics":{...}(선택)}
실행: 허용 목록(ACTIONS)의 action만, kolla-b 호스트의 forced-command 계정으로 'ssh <계정>@<호스트> <action>' 호출.
      실제 명령은 kolla-b 쪽 허용 스크립트가 가짐(이 러너는 임의 명령을 보내지 않음). 모의 실행은 SSH를 호출하지 않음.
환경변수: RUNNER_BIND(기본 127.0.0.1) RUNNER_PORT(기본 8088) RUNNER_TOKEN_FILE RUNNER_SSH_TARGET(user@host)
          RUNNER_SSH_KEY RUNNER_ORIGIN(CORS, 기본 *) RUNNER_SSH(테스트용, 기본 ssh)
"""
import hmac, json, os, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# action -> 확인 문구(없으면 읽기 전용). 대시보드 버튼 data-a 와 같은 이름. site b 단계만 이 러너가 담당.
ACTIONS = {
    "db-status-b": None, "db-monitor-b": None, "db-zl-verify": None, "db-fo-3": None,
    "db-fo-2": "FAILOVER", "db-fb-1": "FAILBACK", "db-fb-4": "FAILBACK",
}
BIND = os.environ.get("RUNNER_BIND", "127.0.0.1")
PORT = int(os.environ.get("RUNNER_PORT", "8088"))
ORIGIN = os.environ.get("RUNNER_ORIGIN", "*")
TOKEN = ""
tf = os.environ.get("RUNNER_TOKEN_FILE", "")
if tf:
    with open(tf, encoding="utf-8") as f:
        TOKEN = f.read().strip()
TARGET = os.environ.get("RUNNER_SSH_TARGET", "")
KEY = os.environ.get("RUNNER_SSH_KEY", "")
SSH = os.environ.get("RUNNER_SSH", "ssh")
LOCK = __import__("threading").Lock()  # 한 번에 한 작업만 (Failover 단계 겹침 방지)


def run_remote(action):
    cmd = [SSH, "-i", KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", TARGET, action]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    out = (p.stdout or "") + (p.stderr or "")
    res = {"ok": p.returncode == 0, "out": out.strip()[-4000:]}
    last = (p.stdout or "").strip().splitlines()[-1:] or [""]
    try:  # 원격 스크립트가 마지막 줄에 JSON(verdict, metrics)을 주면 반영
        j = json.loads(last[0])
        if isinstance(j, dict):
            if j.get("verdict") in ("pass", "fail"):
                res["verdict"] = j["verdict"]
            if isinstance(j.get("metrics"), dict):
                res["metrics"] = {str(k): str(v) for k, v in j["metrics"].items()}
    except ValueError:
        pass
    return res


class H(BaseHTTPRequestHandler):
    server_version = "durian-runner"

    def log_message(self, fmt, *a):  # 토큰 등 헤더는 기록하지 않음
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % a))

    def _send(self, code, obj=None):
        body = json.dumps(obj, ensure_ascii=False).encode() if obj is not None else b""
        self.send_response(code)
        self.send_header("Access-Control-Allow-Origin", ORIGIN)
        self.send_header("Access-Control-Allow-Headers", "X-Token, X-Confirm, X-Dry-Run, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204)

    def do_POST(self):
        if not self.path.startswith("/api/run/"):
            return self._send(404, {"ok": False, "out": "not found"})
        if not TOKEN or not hmac.compare_digest(self.headers.get("X-Token", ""), TOKEN):
            return self._send(401, {"ok": False, "out": "unauthorized"})
        action = self.path[len("/api/run/"):]
        if action not in ACTIONS:
            return self._send(404, {"ok": False, "out": "허용 목록에 없는 action"})
        need = ACTIONS[action]
        h = self.headers.get("X-Dry-Run")
        dry = (h != "0") if need else (h == "1")  # 위험 단계는 기본 모의, 읽기 전용은 기본 실제
        if need and self.headers.get("X-Confirm", "") != need:  # 서버에서 확인 문구 재검증
            return self._send(403, {"ok": False, "out": "확인 문구 불일치 (%s 필요)" % need})
        if dry:
            return self._send(200, {"ok": True, "out": "[모의 실행] 실행하지 않음: ssh %s %s" % (TARGET or "<대상 미설정>", action)})
        if not (TARGET and KEY):
            return self._send(500, {"ok": False, "out": "RUNNER_SSH_TARGET / RUNNER_SSH_KEY 미설정"})
        if not LOCK.acquire(blocking=False):
            return self._send(409, {"ok": False, "out": "다른 작업 실행 중"})
        try:
            self._send(200, run_remote(action))
        except subprocess.TimeoutExpired:
            self._send(200, {"ok": False, "out": "시간 초과(120초)"})
        finally:
            LOCK.release()


if __name__ == "__main__":
    if not TOKEN:
        sys.exit("RUNNER_TOKEN_FILE 필요 (토큰 없이는 시작하지 않음)")
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
