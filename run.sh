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
    # ── 장애를 '하나만' 켜는 조합 (2026-11-07 실측으로 확정) ─────────────────
    # 실제 제공 바이너리는 FAULT_MODE 를 보지 않는다. 세 손잡이가 동시에 살아 있어서
    # 나머지를 정상값으로 고정하지 않으면 엉뚱한 장애가 먼저 터진다.
    #   실측 1: `case cpu 90` 이 CPU 가 아니라 메모리로 죽었다
    #           (MEMORY_LIMIT 이 기본 80 이라 100MB 에서 먼저 자진 종료)
    #   실측 2: `case oom 512` 가 OOM 이 아니라 교착에 빠졌다
    #           (512 는 메모리가 안전해져서 다음 단계인 동시성 작업으로 넘어감)
    #
    # 손잡이별 거동
    #   MEMORY_LIMIT        ≤256 → 한도 초과 시 자진 종료 / ≥257 → 정리하고 생존 / >512 → 부트 FAIL
    #   CPU_MAX_OCCUPY      20 → 정상 / 크게 주면 CpuWorker 가 임계 위반
    #   MULTI_THREAD_ENABLE true → 교착 / false → 순차 처리
    SAFE_MEM=512; SAFE_CPU=20; SAFE_THREAD=false
    case "$MODE" in
      oom)      ENVS="MEMORY_LIMIT=${ARG:-256} CPU_MAX_OCCUPY=$SAFE_CPU MULTI_THREAD_ENABLE=$SAFE_THREAD" ;;
      cpu)      ENVS="MEMORY_LIMIT=$SAFE_MEM CPU_MAX_OCCUPY=${ARG:-90} MULTI_THREAD_ENABLE=$SAFE_THREAD" ;;
      deadlock) ENVS="MEMORY_LIMIT=$SAFE_MEM CPU_MAX_OCCUPY=$SAFE_CPU MULTI_THREAD_ENABLE=${ARG:-true}" ;;
      normal)   ENVS="MEMORY_LIMIT=$SAFE_MEM CPU_MAX_OCCUPY=$SAFE_CPU MULTI_THREAD_ENABLE=$SAFE_THREAD" ;;
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
    dex pkill -f agent-leak-app >/dev/null 2>&1 || true
    sleep 1
    # AGENT_PROC 이 실제 제공 바이너리(agent-leak-app-arm64)면 그걸 띄우고,
    # fault_sim.py 면 python3 로 띄운다. 2026-11-07부터 전자가 기본값이다.
    # 실제 바이너리는 FAULT_MODE 를 보지 않고 MEMORY_LIMIT / CPU_MAX_OCCUPY /
    # MULTI_THREAD_ENABLE 세 값으로만 거동이 갈린다 (부트 시퀀스 6/6 에 그대로 출력된다).
    dex bash -lc "
      . /etc/profile.d/agent-triage.sh
      : > \$AGENT_LOG_DIR/app.log
      if [[ \$AGENT_PROC == *.py ]]; then LAUNCH=\"python3 \$AGENT_HOME/\$AGENT_PROC\"
      else LAUNCH=\"\$AGENT_HOME/\$AGENT_PROC\"; fi
      su - agent -c \"env $ENVS nohup \$LAUNCH > /tmp/app.out 2>&1 &\"
      sleep 2
      echo '--- 부트 시퀀스 ---'
      head -22 /tmp/app.out
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
