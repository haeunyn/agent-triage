# agent-triage

> 📖 **[동료평가 설명서 — 평가표 문항별 설명](docs/동료평가_설명서.md)**
> 2026-11-25 에 받아온 **실제 평가표**의 문항을 하나씩 뜯어서, 항목마다
> ① 확인할 것 ② 실행할 명령 ③ 나올 결과 ④ **설명할 내용**을 정리해 두었습니다.

코디세이 본과정 미션 **B4-2 — 컴퓨터가 갑자기 느려지거나 멈췄을 때 원인 찾아 고치기**

세 가지 시스템 장애(**OOM / CPU Spike / Deadlock**)를 관제 데이터와 로그로
진단하고, GitHub Issue 형태의 기술 리포트로 정리한 결과물입니다.

## ⚠️ 먼저 읽어주세요 — 제공 바이너리에 관하여

이 미션의 산출물은 **코디세이가 배포하는 `agent-app-leak` 바이너리의 실제 동작을
분석한 리포트**입니다. 해당 파일(`agent-app-leak.zip`)을 아직 받지 못해,
리포트의 **증거 수치는 `sim/fault_sim.py`(연습용 시뮬레이터)로 재현한 것**입니다.

| 구분 | 상태 |
|---|---|
| 리포트의 **분석·OS 원리** (3절·4절) | ✅ 바이너리와 무관하게 그대로 적용 |
| 리포트의 **증거 수치** (2절) | 🔄 실제 바이너리 출력으로 **교체 필요** |
| 진단 도구 (`monitor.sh`, `diagnose.sh`) | ✅ 환경변수로 대상 변경, **수정 불필요** |

실제 바이너리를 받으면 이 한 줄만 바꾸면 됩니다:

```bash
export AGENT_PROC=agent-app-leak-arm64
```

리포트에서 교체할 자리는 **`🔄`** 로 표시해 두었습니다.

## 빠른 시작

```bash
./run.sh up                   # Ubuntu 22.04 컨테이너 + 환경 구성
./run.sh case oom 256         # 장애 ① 메모리 누수 재현
./run.sh case cpu 20          # 장애 ② CPU 과점유 재현
./run.sh case deadlock true   # 장애 ③ 교착상태 재현
./run.sh diagnose all         # 증거 자동 수집
./run.sh sched                # 보너스 — 스케줄링 패턴 분석
./run.sh down                 # 정리
```

Docker(OrbStack 또는 Docker Desktop)만 있으면 됩니다.

> **왜 컨테이너인가** — 메모리를 일부러 터뜨리고 CPU 를 일부러 태우는 실습입니다.
> 격리하지 않으면 노트북이 같이 느려집니다. 과제 6절도 격리 환경을 권장합니다.
> `mem_limit: 1g`, `cpus: 2` 로 피해 범위를 컨테이너 안에 묶어두었습니다.

## 산출물

| 파일 | 내용 |
|---|---|
| [`reports/01_OOM.md`](reports/01_OOM.md) | 메모리 누수 → MemoryGuard 자진 종료 |
| [`reports/02_CPU.md`](reports/02_CPU.md) | CPU 과점유 → Watchdog SIGTERM |
| [`reports/03_DEADLOCK.md`](reports/03_DEADLOCK.md) | 교착상태 → 무응답 |
| [`reports/04_SCHEDULING.md`](reports/04_SCHEDULING.md) | **보너스** — 스케줄링 알고리즘 역추론 |
| [`docs/OS개념정리.md`](docs/OS개념정리.md) | 메모리 구조 / CPU 스케줄링 / 교착상태 4대 조건 |

## 세 장애의 Before & After 요약

| | Before | After | 조정한 환경변수 |
|---|---|---|---|
| **OOM** | 256MB → **23초** 생존 | 512MB → **49초** 생존 | `MEMORY_LIMIT` |
| **CPU** | 20% → **8초** 생존 | 90% → **36초** 생존 | `CPU_MAX_OCCUPY` |
| **Deadlock** | `true` → **무응답** | `false` → **정상 완료** | `MULTI_THREAD_ENABLE` |

> **셋 다 '해결'이 아니라 '임시 조치'입니다.** 각 리포트 4절에 왜 그런지와
> 근본 해결 제안을 적었습니다. 환경변수를 바꾼 건 **시간을 산 것**이지
> 누수·과점유·락 순서 문제를 고친 것이 아닙니다.

## 세 장애를 구분하는 법

| | OOM | CPU Spike | Deadlock |
|---|---|---|---|
| 프로세스 | **죽음** (137/SIGKILL) | **죽음** (143/SIGTERM) | **살아 있음** |
| CPU | 낮고 안정 | **급상승** | 낮고 **정체** |
| MEM | **선형 상승** | 변화 없음 | 변화 없음 |
| 로그 | `SELF-TERMINATED` | `WATCHDOG ... ABORT` | **멈춤** |
| 핵심 증거 | `VmRSS` 추이 | `ps -L` 스레드별 CPU | `wchan = futex_wait` |

> **교착상태가 가장 어렵습니다.** PID 살아 있고 포트 LISTEN 유지되고 자원 사용량도
> 낮아서 **모든 지표가 정상으로 보입니다.** Health Check 만으로는 못 잡습니다.

## 구성

```
run.sh                     실행 도우미
setup.sh                   컨테이너 내부 환경 구성
docker/                    Ubuntu 22.04 + 자원 상한 + init(좀비 수거)
bin/
├── monitor.sh             ★ 특정 프로세스 집중 관제 (B4-2 로그 포맷)
├── diagnose.sh            장애 유형별 증거 자동 수집
└── sched_analyze.sh       보너스 — 스케줄링 패턴 분석
sim/
└── fault_sim.py           장애 재현 연습용 (제출 증거용 아님)
reports/                   이슈 리포트 4건
docs/OS개념정리.md          이론 정리
```

### `monitor.sh` 가 B4-1 것과 다른 점

B4-1 은 **시스템 전체**가 관심사였지만, B4-2 는 **특정 프로세스**가 관심사입니다.
과제가 *"시스템 전체 부하가 아닌 특정 프로세스의 CPU 상승 구간을 식별하라"* 고
요구하기 때문입니다.

```
[2026-10-31 06:49:17] PROCESS:fault_sim.py PID:817 CPU:1.0% MEM:1.0% DISK:1% FIREWALL:inactive
```

`ps` 의 `%CPU` 는 **수명 전체 평균**이라 급상승 구간을 놓칩니다.
그래서 `/proc/<pid>/stat` 을 1초 간격으로 두 번 읽어 **그 사이의 사용률**을 직접 계산합니다.

## 수행 중 겪은 문제 4가지

1. **`pgrep -f` 가 래퍼 셸을 잡았다** — 앱이 죽은 뒤에도 `su` 셸의 PID 를 보고하며
   "살아 있다"고 **거짓 보고**. `/proc/<pid>/comm` 으로 셸 종류를 걸러 해결.
2. **CPU 측정이 측정 대상을 바꿨다** — 측정 함수 안의 `sleep(1)` 동안 CPU 를 안 쓰게 되어
   사용률이 절반으로 떨어지고 Watchdog 이 안 터졌다. **잠들지 않는 측정**으로 수정.
3. **`pkill` 이 자기 자신을 죽였다** — 대괄호 트릭도 안 통했다. 그 명령줄의
   **다른 곳에** 대상 문자열이 있었기 때문. 정리를 **별도 명령으로 분리**해 해결.
4. **좀비 프로세스가 쌓였다** — PID 1(`sleep infinity`)이 자식을 거두지 않아
   `<defunct>` 가 누적. compose 에 `init: true` 추가로 해결.

## 제약 사항 준수

| 요구 | 지킨 방법 |
|---|---|
| 리눅스 표준 명령어 사용 | `ps`, `top`, `pgrep`, `kill`, `df`, `free`, `/proc` |
| 바이너리 디컴파일·리버스 엔지니어링 금지 | **하지 않음.** 바이너리를 받지 못해 **명세 기반으로 대역을 작성** |
| 격리 환경 권장 | Docker 컨테이너 + `mem_limit` / `cpus` 상한 |
| 리포트 4단 구조 | `Description / Evidence / Root Cause / Workaround` |
