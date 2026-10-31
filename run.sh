#!/usr/bin/env bash
# agent-triage 실행 도우미
#
#   ./run.sh up                      환경 구성
#   ./run.sh case oom [MEMORY_LIMIT] OOM 재현 + 관제 + 증거 수집
#   ./run.sh case cpu [CPU_MAX]      CPU 과점유 재현
#   ./run.sh case deadlock [true|false]  교착상태 재현/회피
#   ./run.sh case normal             정상 동작 (보너스: 스케줄링 관찰)
#   ./run.sh diagnose [oom|cpu|deadlock|all]
#   ./run.sh sched                   보너스: 스케줄링 패턴 분석
#   ./run.sh shell / down
set -uo pipefail
cd "$(dirname "$0")"

if command -v docker >/dev/null 2>&1; then DOCKER=docker
elif [[ -x /Applications/OrbStack.app/Contents/MacOS/xbin/docker ]]; then
  DOCKER=/Applications/OrbStack.app/Contents/MacOS/xbin/docker
else echo "docker 를 찾을 수 없습니다. OrbStack 을 실행하세요." >&2; exit 1; fi

C=agent-triage
dc()  { "$DOCKER" compose -f docker/docker-compose.yml "$@"; }
dex() { "$DOCKER" exec "$C" "$@"; }

case "${1:-up}" in
  up)
    dc up -d --build
    dex bash /opt/agent-triage/setup.sh
    echo
    echo "다음: ./run.sh case oom"
    ;;
  case)
    MODE="${2:-normal}"; ARG="${3:-}"
    case "$MODE" in
      oom)      ENVS="FAULT_MODE=leak MEMORY_LIMIT=${ARG:-80}" ;;
      cpu)      ENVS="FAULT_MODE=cpu CPU_MAX_OCCUPY=${ARG:-20}" ;;
      deadlock) ENVS="FAULT_MODE=deadlock MULTI_THREAD_ENABLE=${ARG:-true}" ;;
      normal)   ENVS="FAULT_MODE=normal" ;;
      *) echo "case: oom|cpu|deadlock|normal" >&2; exit 1 ;;
    esac
    echo "▶ 실행: $ENVS"
    # 이전 실행이 남아 있으면 그놈을 관제하게 되어 측정이 엉킨다.
    #
    # ⚠️ 이 정리를 **반드시 별도 명령으로** 돌려야 한다.
    #    아래 실행 블록 안에 넣으면, 그 블록의 명령줄에 'fault_sim.py' 가
    #    (앱을 띄우는 부분에) 들어 있어서 pkill -f 가 자기 자신을 죽인다.
    #    대괄호 트릭도 이 경우엔 소용없다 — 패턴이 아니라 '다른 곳에 있는
    #    진짜 문자열'에 매치되기 때문이다.
    dex pkill -f fault_sim.py >/dev/null 2>&1 || true
    sleep 1
    dex bash -lc "
      . /etc/profile.d/agent-triage.sh
      : > \$AGENT_LOG_DIR/app.log
      su - agent -c 'env $ENVS nohup python3 \$AGENT_HOME/fault_sim.py > /tmp/app.out 2>&1 &'
      sleep 2
      echo '--- 부트 시퀀스 ---'
      head -5 /tmp/app.out
      echo
      echo '--- 관제 (최대 60초 또는 프로세스 종료까지) ---'
      su - agent -c '\$AGENT_HOME/bin/monitor.sh --watch 60'
      echo
      echo '--- 앱 로그 마지막 10줄 ---'
      tail -10 /tmp/app.out
    "
    ;;
  diagnose) dex bash -lc "su - agent -c '\$AGENT_HOME/bin/diagnose.sh ${2:-all}'" ;;
  sched)    dex bash -lc "su - agent -c '\$AGENT_HOME/bin/sched_analyze.sh'" ;;
  shell)    "$DOCKER" exec -it "$C" bash -l ;;
  down)     dc down ;;
  *) echo "사용법: ./run.sh [up|case|diagnose|sched|shell|down]" >&2; exit 1 ;;
esac
