#!/usr/bin/env bash
#
# monitor.sh — 대상 프로세스 1개를 집중 관제한다 (미션 B4-2 포맷)
#
# B4-1 의 monitor.sh 와 다른 점:
#   B4-1 은 '시스템 전체'가 관심사였다. B4-2 는 **특정 프로세스**가 관심사다.
#   과제가 "시스템 전체 부하가 아닌 특정 프로세스의 CPU 상승 구간을 식별하라"고
#   요구하기 때문이다. 시스템 전체 CPU 만 보면 "서버가 느리다"까지만 알 뿐
#   "누가 느리게 만들었나"를 답할 수 없다.
#
# 로그 포맷 (과제 PDF 7쪽)
#   [YYYY-MM-DD HH:MM:SS] PROCESS:<name> PID:<pid> CPU:<n>% MEM:<n>% DISK:<n>% FIREWALL:<state>
#
# 사용법
#   ./monitor.sh              1회 측정
#   ./monitor.sh --watch 120  2초 간격으로 120초 동안 연속 측정
set -uo pipefail

[[ -r /etc/profile.d/agent-triage.sh ]] && . /etc/profile.d/agent-triage.sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

TARGET="${AGENT_PROC:-fault_sim.py}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="$LOG_DIR/monitor.log"

WATCH_SECONDS=0
INTERVAL=2
if [[ "${1:-}" == "--watch" ]]; then
    WATCH_SECONDS="${2:-60}"
fi

firewall_state() {
    if command -v ufw >/dev/null 2>&1; then
        if { [[ "$(id -u)" -eq 0 ]] && ufw status 2>/dev/null || sudo -n ufw status 2>/dev/null; } \
             | grep -qi '^Status: active'; then
            echo active
        elif [[ -r /etc/ufw/ufw.conf ]] && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf; then
            echo active
        else
            echo inactive
        fi
    else
        echo n/a
    fi
}

# pgrep -f 는 '명령줄 전체'에서 찾기 때문에, 앱을 띄운 래퍼 셸
#   su - agent -c "... fault_sim.py ..."
# 까지 함께 잡힌다. 실제로 이것 때문에 앱이 죽은 뒤에도 래퍼 셸의 PID 를
# 보고하며 "살아 있다"고 거짓 보고를 했다(CPU/MEM 도 0% 로 나왔다).
#
# 그래서 후보를 모은 뒤 /proc/<pid>/comm 을 읽어 **셸 종류를 걸러낸다.**
# comm 은 실행 파일 이름이라, 파이썬으로 띄운 앱은 python3 이고
# 래퍼는 su/bash/sh 로 나온다. 이 둘은 명령줄만으로는 구분되지 않는다.
find_target_pid() {
    local pid comm
    for pid in $(pgrep -f -- "$TARGET" 2>/dev/null); do
        [[ "$pid" == "$$" ]] && continue
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
        case "$comm" in
            su|sudo|bash|sh|dash|login|env) continue ;;
        esac
        echo "$pid"
        return 0
    done
    return 1
}

sample_once() {
    local pid cpu mem disk fw now
    pid="$(find_target_pid)"
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    disk="$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')"
    fw="$(firewall_state)"

    if [[ -z "$pid" ]]; then
        echo "[$now] PROCESS:$TARGET PID:- CPU:- MEM:- DISK:${disk}% FIREWALL:$fw STATE:NOT_RUNNING"
        return 1
    fi

    # ps 의 %cpu 는 '프로세스 수명 전체의 평균'이라 급상승 구간을 못 잡는다.
    # 그래서 /proc/<pid>/stat 을 1초 간격으로 두 번 읽어 그 사이의 사용률을 직접 센다.
    cpu="$(proc_cpu_percent "$pid")"
    # %mem 은 전체 물리 메모리 대비 RSS 비율이다. 누수 추적에는 이 값이면 충분하다.
    mem="$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')"
    [[ -z "$mem" ]] && mem="-"

    echo "[$now] PROCESS:$TARGET PID:$pid CPU:${cpu}% MEM:${mem}% DISK:${disk}% FIREWALL:$fw"
    return 0
}

proc_cpu_percent() {
    local pid="$1" hz t0 c0 t1 c1
    hz="$(getconf CLK_TCK)"
    read -r t0 c0 < <(cpu_ticks "$pid")
    sleep 1
    read -r t1 c1 < <(cpu_ticks "$pid")
    awk -v c0="$c0" -v c1="$c1" -v t0="$t0" -v t1="$t1" -v hz="$hz" \
        'BEGIN { d = t1 - t0; if (d <= 0) { print "0.0"; exit } printf "%.1f", (c1 - c0) / hz / d * 100 }'
}

cpu_ticks() {
    # /proc/<pid>/stat 의 14,15번째 필드 = utime, stime (클럭 틱 단위)
    # 주의: 2번째 필드(실행 파일명)에 공백이 있을 수 있으므로 ')' 뒤부터 센다.
    local pid="$1" rest
    rest="$(sed -e 's/^.*) //' "/proc/$pid/stat" 2>/dev/null)" || { echo "0 0"; return; }
    awk -v now="$(date +%s.%N)" '{ print now, $12 + $13 }' <<< "$rest"
}

mkdir -p "$LOG_DIR" 2>/dev/null || true

if [[ "$WATCH_SECONDS" -gt 0 ]]; then
    echo "관제 시작: $TARGET  (${WATCH_SECONDS}초, ${INTERVAL}초 간격)"
    end=$(( $(date +%s) + WATCH_SECONDS ))
    while [[ "$(date +%s)" -lt "$end" ]]; do
        line="$(sample_once)"
        status=$?
        echo "$line"
        [[ -w "$LOG_DIR" ]] && echo "$line" >> "$LOG_FILE"
        if [[ "$status" -ne 0 ]]; then
            echo "→ 대상 프로세스가 사라졌습니다. 관제를 종료합니다."
            break
        fi
        sleep "$INTERVAL"
    done
else
    line="$(sample_once)"
    echo "$line"
    [[ -w "$LOG_DIR" ]] && echo "$line" >> "$LOG_FILE"
fi
