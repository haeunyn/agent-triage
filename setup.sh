#!/usr/bin/env bash
# 실습 환경 구성 — 과제 3쪽의 부트 조건을 전부 충족시킨다.
set -euo pipefail

USER_NAME=agent
AGENT_HOME=/home/$USER_NAME/agent-app
LOG_DIR=/var/log/agent-app

echo "== 계정 =="
id "$USER_NAME" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$USER_NAME"
id "$USER_NAME"

echo
echo "== 디렉토리 =="
mkdir -p "$AGENT_HOME"/{upload_files,api_keys,bin} "$LOG_DIR"
echo "agent_api_key_test" > "$AGENT_HOME/api_keys/secret.key"
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME" "$LOG_DIR"
chmod 700 "$AGENT_HOME/api_keys"
chmod 600 "$AGENT_HOME/api_keys/secret.key"
ls -ld "$AGENT_HOME" "$AGENT_HOME"/{upload_files,api_keys} "$LOG_DIR"

echo
echo "== 환경 변수 =="
cat > /etc/profile.d/agent-triage.sh <<ENV
export AGENT_HOME=$AGENT_HOME
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=\$AGENT_HOME/upload_files
export AGENT_KEY_PATH=\$AGENT_HOME/api_keys
export AGENT_LOG_DIR=$LOG_DIR
# 장애 실험용 — 리포트의 Before/After 는 이 값들을 바꿔가며 만든다
export MEMORY_LIMIT=\${MEMORY_LIMIT:-80}
export CPU_MAX_OCCUPY=\${CPU_MAX_OCCUPY:-20}
export MULTI_THREAD_ENABLE=\${MULTI_THREAD_ENABLE:-true}
# 관제 대상 프로세스 이름.
# 실제 제공 바이너리를 쓸 때는 agent-app-leak-arm64 등으로 바꾼다.
export AGENT_PROC=\${AGENT_PROC:-fault_sim.py}
ENV
chmod 644 /etc/profile.d/agent-triage.sh
# shellcheck disable=SC1091
. /etc/profile.d/agent-triage.sh
for n in AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR \
         MEMORY_LIMIT CPU_MAX_OCCUPY MULTI_THREAD_ENABLE AGENT_PROC; do
    printf '  %-22s = %s\n' "$n" "${!n}"
done

echo
echo "== 스크립트/앱 배치 =="
cp /opt/agent-triage/bin/*.sh "$AGENT_HOME/bin/"
cp /opt/agent-triage/sim/fault_sim.py "$AGENT_HOME/"
chown -R "$USER_NAME:$USER_NAME" "$AGENT_HOME"
chmod 750 "$AGENT_HOME"/bin/*.sh
chmod 750 "$AGENT_HOME/fault_sim.py"
ls -l "$AGENT_HOME/bin/" "$AGENT_HOME/fault_sim.py"
echo
echo "✅ 준비 완료"
