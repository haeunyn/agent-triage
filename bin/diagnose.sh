#!/usr/bin/env bash
#
# diagnose.sh — 장애 유형별로 '증거'를 표준 명령으로 수집한다.
#
# 왜 스크립트로 만드나:
#   장애가 터진 순간은 당황해서 무슨 명령을 쳐야 할지 떠오르지 않는다.
#   그 사이 프로세스가 죽으면 증거가 영영 사라진다.
#   무엇을 모을지 **미리 정해두는 것**이 트러블슈팅의 절반이다.
#
# 사용법
#   ./diagnose.sh oom
#   ./diagnose.sh cpu
#   ./diagnose.sh deadlock
#   ./diagnose.sh all
set -uo pipefail

[[ -r /etc/profile.d/agent-triage.sh ]] && . /etc/profile.d/agent-triage.sh
TARGET="${AGENT_PROC:-fault_sim.py}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
# 제공 바이너리는 agent_app.log, 연습용 시뮬레이터는 app.log 에 쓴다 (2026-11-07 실측).
if [[ -s "$LOG_DIR/agent_app.log" ]]; then APP_LOG="$LOG_DIR/agent_app.log"
else APP_LOG="$LOG_DIR/app.log"; fi
CASE="${1:-all}"

hr() { echo "────────────────────────────────────────────────────────"; }
sec() { echo; hr; echo " $*"; hr; }

# monitor.sh 와 같은 이유로 래퍼 셸을 걸러낸다.
# (pgrep -f 는 su/bash 래퍼까지 잡아서 엉뚱한 PID 를 돌려준다)
pid_of() {
    local pid comm
    for pid in $(pgrep -f -- "$TARGET" 2>/dev/null); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
        case "$comm" in su|sudo|bash|sh|dash|login|env) continue ;; esac
        echo "$pid"; return 0
    done
    return 1
}

common_evidence() {
    sec "프로세스 존재 확인 (ps -ef | grep)"
    ps -ef | grep -- "$TARGET" | grep -v grep || echo "(프로세스 없음)"

    local pid; pid="$(pid_of)"
    if [[ -n "$pid" ]]; then
        sec "프로세스 요약 (ps -p $pid -o ...)"
        ps -p "$pid" -o pid,ppid,stat,%cpu,%mem,rss,etime,cmd
        echo
        echo "STAT 열 읽는 법:  R 실행중  S 대기(인터럽트 가능)  D 대기(불가)  Z 좀비  T 멈춤"
        echo "                  l 멀티스레드  + 포그라운드"
    fi
}

case_oom() {
    sec "【OOM】 메모리 사용량 추이 (monitor.log 최근 15줄)"
    tail -15 "$LOG_DIR/monitor.log" 2>/dev/null || echo "(관제 로그 없음)"

    sec "【OOM】 MemoryGuard 관련 로그"
    grep -E 'MemoryGuard|MemoryWorker|SELF-TERMINATED|Memory limit|Cache Flushed' "$APP_LOG" 2>/dev/null | tail -10 \
        || echo "(해당 로그 없음)"

    local pid; pid="$(pid_of)"
    if [[ -n "$pid" ]]; then
        sec "【OOM】 메모리 상세 (/proc/$pid/status)"
        grep -E '^(VmRSS|VmSize|VmPeak|Threads):' "/proc/$pid/status" 2>/dev/null
        echo
        echo "VmRSS  = 실제 물리 메모리 점유량 (누수 추적은 이 값을 본다)"
        echo "VmSize = 가상 메모리 주소 공간 (실제로 안 쓰는 것도 포함되어 늘 크다)"
        echo "VmPeak = 지금까지의 최대 VmSize"
    fi

    sec "【OOM】 시스템 메모리 여유"
    free -m 2>/dev/null || awk '/Mem(Total|Available|Free)/' /proc/meminfo
}

case_cpu() {
    sec "【CPU】 CPU 사용률 추이 (monitor.log 최근 15줄)"
    tail -15 "$LOG_DIR/monitor.log" 2>/dev/null || echo "(관제 로그 없음)"

    sec "【CPU】 Watchdog 관련 로그"
    grep -E 'Watchdog|WATCHDOG|CPU occupancy|CpuWorker|Threshold Violated' "$APP_LOG" 2>/dev/null | tail -10 \
        || echo "(해당 로그 없음)"

    sec "【CPU】 프로세스별 CPU 상위 (ps 정렬)"
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -8

    local pid; pid="$(pid_of)"
    if [[ -n "$pid" ]]; then
        sec "【CPU】 스레드별 CPU (ps -L -p $pid)"
        ps -L -p "$pid" -o pid,tid,%cpu,stat,comm
        echo
        echo "한 스레드만 CPU 가 높으면 → 단일 루프 과점유"
        echo "여러 스레드가 고르게 높으면 → 병렬 연산 부하"
    fi
}

case_deadlock() {
    local pid; pid="$(pid_of)"
    sec "【Deadlock】 PID 존재 확인 — '죽지 않았다'가 핵심 증거"
    if [[ -n "$pid" ]]; then
        echo "PID $pid 살아 있음 ✅ (종료된 게 아니라 '멈춰 있다')"
        ps -p "$pid" -o pid,stat,%cpu,%mem,etime,cmd
    else
        echo "(프로세스 없음 — 이건 데드락이 아니라 종료된 상황입니다)"
        return
    fi

    sec "【Deadlock】 스레드별 상태 (ps -L) — 모두 S(대기)면 교착 의심"
    ps -L -p "$pid" -o pid,tid,stat,%cpu,wchan:20,comm
    echo
    echo "wchan = 커널 안에서 '무엇을 기다리는 중인지'. futex 계열이면 락 대기다."

    sec "【Deadlock】 CPU/MEM 정체 확인 (3회 측정, 값이 안 변해야 함)"
    for i in 1 2 3; do
        printf '  %d회: ' "$i"
        ps -p "$pid" -o %cpu=,%mem= | tr -s ' '
        sleep 2
    done
    echo "  → 세 번 모두 같으면 '일을 안 하고 멈춰 있다'는 객관적 증거입니다."

    sec "【Deadlock】 마지막 로그 기록 (멈춘 지점)"
    tail -8 "$APP_LOG" 2>/dev/null || echo "(앱 로그 없음)"
    echo
    echo "WAITING / BLOCKED 에서 멈춰 있고 그 뒤로 아무것도 없으면,"
    echo "각 스레드가 상대의 락을 기다리는 순환 대기 상태로 추론할 수 있습니다."

    sec "【Deadlock】 로그가 멈춘 지 얼마나 됐나"
    if [[ -f "$APP_LOG" ]]; then
        echo "  마지막 기록: $(date -r "$APP_LOG" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        echo "  현재 시각  : $(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

echo "╔════════════════════════════════════════════════════════╗"
echo "║  장애 진단 — case: $CASE"
echo "║  대상: $TARGET"
echo "║  시각: $(date '+%Y-%m-%d %H:%M:%S')"
echo "╚════════════════════════════════════════════════════════╝"

common_evidence
case "$CASE" in
    oom)      case_oom ;;
    cpu)      case_cpu ;;
    deadlock) case_deadlock ;;
    all)      case_oom; case_cpu; case_deadlock ;;
    *) echo "사용법: ./diagnose.sh [oom|cpu|deadlock|all]" >&2; exit 1 ;;
esac
echo
hr
echo " 수집 완료"
hr
