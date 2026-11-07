#!/usr/bin/env bash
#
# sched_analyze.sh — 보너스. 로그 타임스탬프로 스케줄링 알고리즘을 역추론한다.
#
# 아이디어:
#   로그에 찍힌 [Thread-X] 의 **등장 순서**만 보면 스케줄링 방식이 드러난다.
#     - 한 스레드가 끝까지 간 뒤 다음이 시작 → FCFS (먼저 온 것부터 끝까지)
#     - 특정 스레드만 자주 등장          → Priority (우선순위)
#     - A,B,C 가 번갈아 조금씩 진행       → Round-Robin (시간 할당량씩 돌아가며)
#
# 사용법: ./sched_analyze.sh [로그파일]
set -uo pipefail

[[ -r /etc/profile.d/agent-triage.sh ]] && . /etc/profile.d/agent-triage.sh
# 로그 파일 이름이 앱에 따라 다르다 (2026-11-07 실측).
#   제공 바이너리 agent-leak-app-arm64 → agent_app.log
#   연습용 시뮬레이터 fault_sim.py     → app.log
# 인자로 직접 줄 수도 있고, 안 주면 있는 쪽을 자동으로 고른다.
_LD="${AGENT_LOG_DIR:-/var/log/agent-app}"
if [[ -n "${1:-}" ]]; then LOG="$1"
elif [[ -s "$_LD/agent_app.log" ]]; then LOG="$_LD/agent_app.log"
else LOG="$_LD/app.log"; fi

if [[ ! -r "$LOG" ]]; then
    echo "[ERROR] 로그를 읽을 수 없습니다: $LOG" >&2
    exit 1
fi

# 제공 바이너리는 시작할 때 등록 목록을 한 줄로 찍는다:
#   [Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
# 이 한 줄에 세 스레드가 다 들어 있어서 집계와 실행 순서를 오염시킨다
# (2026-11-07 실측: [2] 맨 앞에 A B C 가 붙고 교체 횟수가 부풀었다).
# 실제 작업 줄만 남긴다.
tlines() { grep -E 'Thread-[A-Za-z0-9]+' "$LOG" 2>/dev/null | grep -v 'Registered Tasks'; }

echo "====== SCHEDULING PATTERN ANALYSIS ======"
echo "  대상 로그: $LOG"
echo

echo "[1] 스레드별 로그 건수"
# 대괄호를 포함해 찾으면 안 된다. 제공 바이너리는 [Worker-Thread-1] 처럼
# 접두어가 붙어서 '\[Thread-' 패턴에 걸리지 않는다 (2026-11-07 실측: 이 항목이
# 통째로 비어 나왔다). [2]·[3] 과 같은 패턴으로 통일한다.
tlines | grep -oE 'Thread-[A-Za-z0-9]+' | sort | uniq -c | sort -rn | sed 's/^/    /'
echo

echo "[2] 실행 순서 (등장 순서대로 나열)"
tlines | grep -oE 'Thread-[A-Za-z0-9]+' | head -30 | tr '\n' ' ' | fold -w 68 | sed 's/^/    /'
echo
echo

echo "[3] 교체(context switch) 횟수 — 직전과 다른 스레드가 나온 횟수"
tlines | grep -oE 'Thread-[A-Za-z0-9]+' | awk '
  NR == 1 { prev = $0; total = 1; next }
  { total++; if ($0 != prev) { switches++ }; prev = $0 }
  END {
    if (total == 0) { print "    (데이터 없음)"; exit }
    printf "    전체 %d건 중 교체 %d회 (%.1f%%)\n", total, switches, switches * 100 / total
  }'
echo

echo "[4] 진행률 끼어듦 검사 — 한 스레드가 100% 되기 전에 다른 스레드가 등장하는가"
awk '
  match($0, /Thread-[A-Za-z0-9]+/) {
    t = substr($0, RSTART, RLENGTH)
    if (match($0, /\([0-9]+%\)/)) {
      p = substr($0, RSTART + 1, RLENGTH - 3) + 0
      if (seen_any && t != last_t && last_p > 0 && last_p < 100) interleave++
      last_t = t; last_p = p; seen_any = 1
    }
  }
  END {
    if (interleave > 0)
      printf "    끼어듦 %d회 관측 → 순차 처리(FCFS)가 아니다\n", interleave
    else
      print "    끼어듦 없음 → 순차 처리(FCFS) 가능성"
  }' "$LOG"
echo

echo "[5] 결론"
tlines | grep -oE 'Thread-[A-Za-z0-9]+' | awk '
  { count[$0]++; total++; if ($0 != prev) switches++; prev = $0 }
  END {
    if (total == 0) { print "    (데이터 없음)"; exit }
    n = 0; max = 0; min = total
    for (t in count) { n++; if (count[t] > max) max = count[t]; if (count[t] < min) min = count[t] }
    ratio = switches * 100 / total
    printf "    스레드 %d개, 최다 %d건 / 최소 %d건", n, max, min
    if (n > 1 && max <= min * 1.3) printf " → 고르게 분배됨 (우선순위 편중 없음)\n"
    else printf " → 편중 있음 (Priority 가능성)\n"
    if (ratio > 50)
      print "    교체가 잦고 분배가 고르다 → Round-Robin 으로 추론"
    else if (ratio < 10)
      print "    교체가 거의 없다 → FCFS 로 추론"
    else
      print "    판단 보류 — 샘플을 더 모으세요"
  }'
echo
echo "※ 이 스크립트는 '근거'를 모아줄 뿐 결론을 대신 내려주지 않습니다."
echo "   리포트에는 위 수치를 인용해 직접 논증을 쓰세요."
