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

# ── 프로세스 트리 전체를 재는 이유 (2026-11-07 실측으로 추가) ──────────────
# 제공 바이너리 agent-leak-app-arm64 는 부모가 포트만 열어두고 실제 작업은
# **워커 자식 프로세스**에게 맡긴다. 그래서 부모만 재면 누수가 한창일 때도
# CPU 0.0% / MEM 0.0% 로 찍힌다.
#   실측: 부모 PID 140 은 끝까지 MEM 0.0% — 워커 142 가 275MB 까지 쌓고 자진 종료.
# 관제 도구가 "앱이 멀쩡하다"고 거짓 보고하면 쓸모가 없으므로,
# 보고 PID 는 부모로 고정하고 수치는 **자손까지 합산**한다.
# ⚠️ 방문 기록(seen)이 반드시 있어야 한다.
#   children 은 '스레드마다' 파일이 따로 있어서(/proc/PID/task/TID/children)
#   같은 자식이 여러 번 잡힌다. 중복을 그대로 큐에 넣으면 같은 PID 를 계속
#   다시 펼쳐서 큐가 끝없이 불어난다 — 2026-11-07 에 앱이 죽지 않는 설정
#   (MEMORY_LIMIT=512)에서 샘플 한 번이 끝나지 않아 관제가 멈췄다.
# 안전장치로 탐색 개수 상한(MAX_TREE_PIDS)도 둔다.
MAX_TREE_PIDS=256
tree_pids() {
    local queue=("$1") cur kid count=0
    local -A seen=()
    seen["$1"]=1
    while (( ${#queue[@]} > 0 )); do
        cur="${queue[0]}"; queue=("${queue[@]:1}")
        printf '%s\n' "$cur"
        (( ++count >= MAX_TREE_PIDS )) && return 0
        for kid in $(cat /proc/"$cur"/task/*/children 2>/dev/null); do
            [[ -n "${seen[$kid]:-}" ]] && continue
            seen["$kid"]=1
            queue+=("$kid")
        done
    done
}

tree_mem_percent() {
    local total rss=0 p v
    total="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
    for p in $(tree_pids "$1"); do
        v="$(awk '/^VmRSS:/ { print $2 }' "/proc/$p/status" 2>/dev/null)"
        [[ -n "$v" ]] && rss=$(( rss + v ))
    done
    awk -v r="$rss" -v t="$total" \
        'BEGIN { if (t <= 0) { print "0.0"; exit } printf "%.1f", r * 100 / t }'
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
    # 전체 물리 메모리 대비 RSS 비율. 워커 자식까지 합산한다(tree_mem_percent 주석 참고).
    mem="$(tree_mem_percent "$pid")"
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
    # 두 샘플 사이에 워커 자식이 종료하면 '트리 합계 틱'이 줄어들어 음수가 나온다
    # (2026-11-07 실측: -7.9%, -8.8%). 사용률은 음수일 수 없으므로 0 으로 깎는다.
    # 이 구간은 '프로세스가 사라지는 중'이라 다음 샘플에서 NOT_RUNNING 으로 잡힌다.
    awk -v c0="$c0" -v c1="$c1" -v t0="$t0" -v t1="$t1" -v hz="$hz" \
        'BEGIN {
             d = t1 - t0
             if (d <= 0) { print "0.0"; exit }
             v = (c1 - c0) / hz / d * 100
             if (v < 0) v = 0
             printf "%.1f", v
         }'
}

cpu_ticks() {
    # /proc/<pid>/stat 의 14,15번째 필드 = utime, stime (클럭 틱 단위)
    # 주의: 2번째 필드(실행 파일명)에 공백이 있을 수 있으므로 ')' 뒤부터 센다.
    # 메모리와 같은 이유로 자손 프로세스의 틱까지 합산한다.
    local pid="$1" rest p sum=0 add
    for p in $(tree_pids "$pid"); do
        rest="$(sed -e 's/^.*) //' "/proc/$p/stat" 2>/dev/null)" || continue
        [[ -z "$rest" ]] && continue
        add="$(awk '{ print $12 + $13 }' <<< "$rest")"
        sum=$(( sum + add ))
    done
    echo "$(date +%s.%N) $sum"
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
