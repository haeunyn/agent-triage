# [Bug] Deadlock - 멀티스레드 환경에서 교착상태 발생으로 프로세스 무응답

> **증거 데이터 출처**
> 코디세이 제공 바이너리 `agent-leak-app-arm64` 를 직접 실행해 얻은 실측값입니다.
> 측정 일시 **2026-11-07 09:27~09:41 (KST)**, 환경 Docker `agent-triage` (Ubuntu, aarch64, 8코어).
> 재현 명령은 **4-3절**에 적었습니다.

---

## 1. Description (현상 설명)

`agent-leak-app` 실행 후 약 1초 뒤 **프로세스가 멈춥니다.**
그런데 **종료되지는 않습니다.** PID 는 그대로 살아 있고, 로그 출력만 완전히 끊깁니다.

| 항목 | 내용 |
|---|---|
| **언제** | 두 워커 스레드가 각자 첫 락을 잡은 **약 2초 뒤** (09:27:55 점유 → 09:27:57 교착) |
| **조건** | `MULTI_THREAD_ENABLE=true` · `MEMORY_LIMIT=512` · `CPU_MAX_OCCUPY=20` |
| **PID** | **살아 있음** — 종료 메시지 없음. 관제 60초 동안 계속 존재 |
| **CPU/MEM** | 0.1% / 0.3% 에서 **완전 정지** (2초 간격 3회 측정 동일) |
| **스레드** | 3개, 전부 `S`(sleeping) |
| **로그** | `WAITING for [...]... (Status: BLOCKED)` 이후 **한 줄도 없음** |
| **대기 자원** | `Shared_Memory_A` ↔ `Socket_Pool_B` |

> **이 케이스가 앞의 둘과 근본적으로 다른 점:**
> OOM·CPU 는 **프로세스가 죽습니다.** 죽으면 최소한 "죽었다"는 사실은 알 수 있습니다.
> 교착상태는 **살아 있는데 아무 일도 안 합니다.** 모니터링이 "프로세스 살아 있음 ✅"
> 만 본다면 **장애를 정상으로 보고합니다.** 가장 발견하기 어려운 유형입니다.

---

## 2. Evidence & Logs (증거 자료)

### 2-1. PID 존재 증거 — "죽은 게 아니라 멈췄다"

```bash
$ ps -ef | grep agent-leak | grep -v grep
agent  16880      1  0 09:40 ?  00:00:00 /home/agent/agent-app/agent-leak-app-arm64
agent  16881  16880  0 09:40 ?  00:00:00 /home/agent/agent-app/agent-leak-app-arm64

$ ps -p 16881 -o pid,stat,%cpu,%mem,etime,cmd
    PID STAT %CPU %MEM     ELAPSED CMD
  16881 SNl   0.1  0.3       00:34 /home/agent/agent-app/agent-leak-app-arm64
```

프로세스가 **둘** 입니다. 16880 이 부모, **16881 이 실제 작업을 하는 워커**입니다.
교착에 빠진 쪽은 워커입니다.

**`STAT` 열이 핵심 증거입니다.**

| 문자 | 의미 |
|---|---|
| **`S`** | Sleeping — **대기 중** (무언가를 기다리고 있다) |
| `N` | nice 값이 높음(낮은 우선순위) — 앱이 기동 시 `[SafetyGuard] Process priority lowered (nice=10)` 를 찍는다 |
| **`l`** | multi-threaded — 멀티스레드 프로세스 |
| (`R` 이면) | Running — 실제로 일하는 중 |

`R` 이 아니라 `S` 라는 것은 **CPU 를 쓰고 있지 않다**는 뜻입니다.
무한 루프라면 `R` 이어야 합니다. **무한 루프가 아니라 무한 대기입니다.**

> ⚠️ **PID 를 찾을 때 주의.** `pgrep -f agent-leak-app-arm64` 는 **명령줄 전체**를
> 검색하므로, 앱 이름이 들어간 **진단 명령 자신까지** 잡아서 엉뚱한 PID 를 줍니다.
> 실제로 이 때문에 첫 캡처가 통째로 실패했습니다.
> `comm` 은 리눅스에서 **15자로 잘려** `agent-leak-app-` 가 되므로 `pgrep -x` 도
> 안 맞습니다. 다음과 같이 **명령줄을 앵커**해야 합니다.
> ```bash
> pgrep -f "^/home/agent/agent-app/agent-leak-app-arm64$"
> ```

### 2-2. 스레드별 상태 — 3개 전부 대기

```bash
$ ps -L -p 16881 -o pid,tid,stat,%cpu,wchan:20,comm
    PID     TID STAT %CPU WCHAN                COMMAND
  16881   16881 SNl   0.1 -                    agent-leak-app-
  16881   16882 SNl   0.0 -                    agent-leak-app-
  16881   16883 SNl   0.0 -                    agent-leak-app-
```

**스레드 3개가 전부 `S`(대기)이고, 어느 것도 `R`(실행)이 아닙니다.**
`ps -L` 로 스레드까지 보는 이유는, 한 스레드만 바쁘면 단일 루프 과점유이고
여러 스레드가 고르게 바쁘면 병렬 연산 부하인데 — **아무도 바쁘지 않으면
전원이 무언가를 기다린다**는 뜻이기 때문입니다.

#### ⚠️ `wchan` 을 이 환경에서는 읽을 수 없었습니다

`wchan`(wait channel)은 **커널 안에서 무엇을 기다리는지** 보여주는 값입니다.
락 대기라면 `futex_wait` 가 나와야 교착의 커널 레벨 물증이 됩니다.
**하지만 이 컨테이너에서는 전부 막혀 있었습니다.**

```bash
$ cat /proc/16881/task/*/wchan      → 0  (전부)
$ cat /proc/16881/task/*/syscall    → Operation not permitted
$ cat /proc/16881/task/*/stack      → Permission denied   (root 로도 거부)
```

Docker 기본 seccomp/AppArmor 정책이 `/proc/<pid>/syscall` 과 `/proc/<pid>/stack` 을
차단하고, `wchan` 도 노출되지 않습니다. **그래서 `futex_wait` 증거는 제시하지 않습니다.**
없는 증거를 적지 않는 것이 맞고, 대신 아래 셋으로 교착을 입증합니다.

다만 **부모 프로세스의 `wchan` 은 읽혔습니다.**

```
    PID     TID STAT %CPU WCHAN                COMMAND
  12564   12564 S     0.1 do_wait              agent-leak-app-
```

`do_wait` 는 **자식 프로세스가 끝나기를 기다리는 중**이라는 뜻입니다.
워커가 교착에 빠졌으니 부모는 영원히 기다립니다. **대기가 위로 전파된 모습**입니다.

### 2-3. CPU/MEM 정체 증거 — 2초 간격 3회 측정

```
  1회:  0.1  0.3
  2회:  0.1  0.3
  3회:  0.1  0.3
```

```bash
$ grep -E '^(Name|State|Threads|VmRSS|VmSize|VmPeak):' /proc/16881/status
Name:     agent-leak-app-
State:    S (sleeping)
VmPeak:     235284 kB
VmSize:     169748 kB
VmRSS:       14020 kB
Threads:         3
```

**세 번 모두 소수점까지 똑같습니다.** 일을 하고 있다면 값이 흔들립니다.
`State: S (sleeping)` 와 `Threads: 3` 이 `ps -L` 결과와 일치합니다.

> `VmPeak`(235MB)이 `VmSize`(169MB)보다 큰 것은 **한때 더 썼다가 줄었다**는 뜻입니다.
> 교착 전에 메모리 작업을 하다가 멈춘 흔적입니다.
> 누수 추적에 쓰는 값은 `VmRSS`(실제 물리 메모리, 14MB)입니다.

### 2-4. 마지막 로그 — 순환 대기가 그대로 찍혀 있습니다

```
09:27:50,211 [WARNING] [AgentWorker] Initializing concurrent transaction processors...
09:27:50,211 [WARNING] [System] CAUTION: Strict resource locking is enabled.
09:27:55,240 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
09:27:55,241 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
09:27:55,241 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
09:27:55,241 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
09:27:55,242 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
09:27:55,242 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
09:27:55,242 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
09:27:57,252 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
09:27:57,253 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
09:27:57,256 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
09:27:57,257 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
                                                   ← 이후 아무 기록 없음 (60초 관제 끝까지)
```

**이 로그 한 장이 교착의 완전한 증거입니다.**

| 시각 | Worker-Thread-1 | Worker-Thread-2 |
|---|---|---|
| 09:27:55 | `Shared_Memory_A` **점유** | `Socket_Pool_B` **점유** |
| 09:27:57 | `Socket_Pool_B` **대기** | `Shared_Memory_A` **대기** |

서로가 쥔 것을 서로 기다립니다. **A → B → A 의 고리**가 닫혔습니다.

### 2-5. ⚠️ 관제 로그는 60초 내내 "정상"이었습니다

**이 케이스에서 가장 무서운 부분입니다.**

```
관제 시작: agent-leak-app-arm64  (60초, 2초 간격)
[2026-11-07 09:27:50] PROCESS:agent-leak-app-arm64 PID:12564 CPU:0.0% MEM:0.5% DISK:1% FIREWALL:inactive
[2026-11-07 09:27:53] PROCESS:agent-leak-app-arm64 PID:12564 CPU:0.0% MEM:0.5% DISK:1% FIREWALL:inactive
[2026-11-07 09:27:56] PROCESS:agent-leak-app-arm64 PID:12564 CPU:1.0% MEM:0.5% DISK:1% FIREWALL:inactive
   ...                                              (중략 — 20개 샘플 전부 동일)
[2026-11-07 09:28:48] PROCESS:agent-leak-app-arm64 PID:12564 CPU:0.0% MEM:0.4% DISK:1% FIREWALL:inactive
```

**`STATE:NOT_RUNNING` 이 한 번도 나오지 않았습니다.** 프로세스는 살아 있고,
포트도 열려 있고, CPU·메모리도 임계값을 넘지 않습니다.
**관제 도구 입장에서는 완벽하게 건강한 앱입니다.**

| | OOM (리포트 01) | CPU (리포트 02) | **교착 (이 리포트)** |
|---|---|---|---|
| 프로세스 | 32초 뒤 사라짐 | 사라짐/멈춤 | **끝까지 살아 있음** |
| 관제가 알아채나 | ✅ `NOT_RUNNING` | △ 앱 로그 필요 | ❌ **전혀 모름** |

> **"프로세스 살아 있음 ✅ + 포트 열림 ✅" 만 보는 헬스체크는 교착을 절대 못 잡습니다.**
> 잡으려면 **일이 진행되고 있는지**를 봐야 합니다 — 로그가 늘어나는지,
> 처리 건수가 증가하는지, 응답이 실제로 돌아오는지.
> 4-4 에 이 제안을 적었습니다.

## 3. Root Cause Analysis (원인 분석)

### 3-1. 교착상태(Deadlock)란

**둘 이상의 스레드가 서로가 가진 자원을 기다려 모두 영원히 진행하지 못하는 상태.**

대표 비유가 **식사하는 철학자들 문제**입니다. 둥근 식탁에 철학자 5명이 앉고
포크는 5개, 각자 양옆의 포크 2개를 들어야 식사할 수 있습니다. 모두가 동시에
**왼쪽 포크를 먼저 집으면**, 전원이 오른쪽 포크를 기다리며 영원히 굶습니다.
아무도 잘못한 사람이 없는데 전체가 멈춥니다.

### 3-2. 교착상태 4대 조건 — 이 장애에 모두 성립

**네 가지가 동시에 성립해야만** 교착상태가 됩니다. 하나만 깨면 발생하지 않습니다.

| 조건 | 뜻 | 이 장애에서 |
|---|---|---|
| **상호 배제**<br>Mutual Exclusion | 한 자원은 한 번에 하나만 쓸 수 있다 | `LOCK ACQUIRED: [Shared_Memory_A]` — 한 스레드만 점유 |
| **점유 대기**<br>Hold and Wait | 이미 쥔 채로 다른 것을 기다린다 | Thread-1 은 `Shared_Memory_A` 를 **쥔 채로**(`Holding...`) `Socket_Pool_B` 를 기다림 |
| **비선점**<br>No Preemption | 남이 쥔 것을 강제로 뺏을 수 없다 | `Strict resource locking is enabled` — 소유자가 놓아야만 풀림 |
| **순환 대기**<br>Circular Wait | 대기 관계가 고리를 이룬다 | **Thread-1 → B → Thread-2 → A → Thread-1** |

```
   Shared_Memory_A                 Socket_Pool_B
         │ 점유                          │ 점유
   [Worker-Thread-1] ──── 대기 ────→ [Worker-Thread-2]
         ↑                               │
         └────────────── 대기 ────────────┘
```

**네 조건이 2-4 의 로그에 전부 글자로 찍혀 있습니다.**
`Strict resource locking is enabled` 가 비선점을, `(Holding...)` 가 점유 대기를,
두 줄의 `WAITING for` 가 순환 대기를 그대로 보여줍니다.

### 3-3. 왜 "순서"가 원인인가

A 와 B 가 **같은 순서로** 락을 잡았다면 교착은 일어나지 않습니다.

```
A: lock1 → lock2        A: lock1 → lock2
B: lock2 → lock1  ❌    B: lock1 → lock2  ✅
   (반대 순서)              (같은 순서)
```

같은 순서면 먼저 `lock1` 을 잡은 쪽이 끝까지 진행하고, 다른 쪽은 기다렸다가
순서대로 받습니다. **고리가 생기지 않습니다.**

> 그래서 교착상태는 **"락을 잘못 썼다"기보다 "락을 잡는 순서를 정하지 않았다"** 는
> 설계 누락에 가깝습니다. 코드만 보면 양쪽 다 멀쩡해 보이는 게 함정입니다.

### 3-4. 왜 발견하기 어려운가

| | 보이는 것 | 놓치는 이유 |
|---|---|---|
| 프로세스 | **살아 있음** | "죽지 않았으니 정상"으로 오판 |
| 포트 | **LISTEN 유지** | 헬스체크가 통과해버림 |
| CPU/MEM | **낮고 안정적** | 자원 경고가 안 울림 |
| 로그 | **멈춤** | "조용하니 한가한가 보다" |

**모든 지표가 '정상'으로 보입니다.** 그래서 `monitor.sh` 의 Health Check 만으로는
교착을 못 잡습니다. **"로그가 N분째 멈춰 있다"** 같은 **무응답 감지**가 따로 필요합니다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 내용

환경변수 `MULTI_THREAD_ENABLE` 을 **`true` → `false`** 로 변경했습니다.

```bash
export MULTI_THREAD_ENABLE=false
```

단일 스레드로 동작하면 **락 경쟁 자체가 없어지므로** 교착이 성립하지 않습니다.
(4대 조건 중 **순환 대기**가 깨집니다 — 대기할 상대가 없습니다)

### 4-2. Before & After

| | Before (`MULTI_THREAD_ENABLE=true`) | After (`=false`) |
|---|---|---|
| **동작** | 약 2초 뒤 **무응답** | **계속 정상 가동** |
| **PID** | 살아 있으나 멈춤 | 살아 있고 **일하고 있음** |
| **스레드** | 3개, 전부 `S`(sleeping) | — |
| **관제 샘플** | 20개 (전부 동일값) | 20개 (값이 계속 변함) |
| **MEM** | 0.5% → 0.4% **고정** | 힙이 425 → 500MB 로 **상승** |
| **마지막 로그** | `WAITING for [...]... (Status: BLOCKED)` 이후 **침묵** | 로그가 계속 쌓임 |

```
# After 로그 — 두 워커가 모두 일하고 있다
2026-11-07 09:29:54,233 [INFO] [CpuWorker]    Peak reached (20.00%). Starting cooldown...
2026-11-07 09:29:55,244 [INFO] [CpuWorker]    Current Load: 20.00%
2026-11-07 09:29:56,948 [INFO] [MemoryWorker] Current Heap: 425MB
2026-11-07 09:29:58,377 [INFO] [CpuWorker]    Current Load: 18.68%
2026-11-07 09:30:00,007 [INFO] [MemoryWorker] Current Heap: 450MB
2026-11-07 09:30:01,508 [INFO] [CpuWorker]    Current Load: 16.43%
2026-11-07 09:30:03,048 [INFO] [MemoryWorker] Current Heap: 475MB
2026-11-07 09:30:04,634 [INFO] [CpuWorker]    Current Load: 9.63%
2026-11-07 09:30:06,079 [INFO] [MemoryWorker] Current Heap: 500MB
2026-11-07 09:30:07,762 [INFO] [CpuWorker]    Current Load: 6.69%
```

**Before 와 After 를 가르는 것은 "로그가 계속 쌓이는지" 하나입니다.**
프로세스 존재·포트·CPU·메모리 수치만 보면 둘이 구별되지 않습니다
(2-5 참고). **진행 여부가 유일한 판별 기준**입니다.

> 리포트 초안에는 After 가 `All tasks completed normally` 를 찍고 **정상 종료**한다고
> 적혀 있었는데, 실제 바이너리는 **종료하지 않는 상주 서비스**입니다.
> 10개 작업을 끝내고 나가는 구조가 아니라 계속 돌면서 메모리·CPU 워커를 굴립니다.
> (그 문장은 진단 연습용으로 만든 시뮬레이터의 거동이었습니다.)

### 4-3. 검증 결과 해석

> **교착은 사라졌지만, 병렬 처리도 함께 사라졌습니다.**
> `MULTI_THREAD_ENABLE=false` 는 **동시 트랜잭션 처리를 끄는** 설정입니다
> (Before 로그의 `Initializing concurrent transaction processors...` 가 사라집니다).
> 락 경쟁이 없어져 교착은 성립하지 않지만, **동시에 처리할 수 있는 작업 수가 줍니다.**
>
> 즉 이 조치는 **"동시성을 포기해서 안정성을 산 것"** 입니다.
> 트래픽이 적다면 쓸 만한 임시 조치지만, 처리량이 중요한 서비스에서는
> 다른 장애(응답 지연)로 바뀔 뿐입니다.
>
> **처리량 손실이 실제로 얼마인지는 측정하지 못했습니다.** 이 앱은 작업 건수를
> 로그에 찍지 않아서(힙 크기와 부하율만 찍습니다) 비교할 지표가 없었습니다.
> 숫자 없이 "몇 배 떨어진다"고 쓰지 않았습니다.

### 4-4. 근본적 해결 제안

4대 조건 중 **하나만 깨면** 교착이 발생하지 않습니다. 현실적인 순서대로:

| 우선순위 | 방법 | 깨는 조건 | 설명 |
|---|---|---|---|
| **1** | **락 순서 통일** | 순환 대기 | 모든 스레드가 **항상 같은 순서**로 락을 잡게 한다. 가장 확실하고 비용이 없다 |
| 2 | **타임아웃** | 점유 대기 | `acquire(timeout=N)`. 못 잡으면 **가진 것을 놓고 물러난다**. 영원히 멈추진 않는다 |
| 3 | **락 한 개로 합치기** | 상호 배제 | 보호할 자원이 늘 함께 쓰인다면 락을 하나로. 단순하지만 병렬성이 준다 |
| 4 | **무응답 감지 추가** | (탐지) | 해결은 아니지만, **로그가 N분째 멈추면 경고**. 발견 시간을 줄인다 |

> **1번을 가장 먼저 해야 합니다.** 코드 몇 줄만 바꾸면 되고 성능 손해가 없습니다.
> 이 앱이라면 **"락은 항상 `Shared_Memory_A` → `Socket_Pool_B` 순서로 잡는다"** 를
> 팀 규칙으로 문서화하는 것이 실무에서 가장 흔한 해법입니다.
> Before 로그에서 Thread-2 가 `Socket_Pool_B` 를 먼저 잡은 것이 고리를 닫았습니다.

### 4-5. 재현 방법

```bash
./run.sh up
./run.sh case deadlock true     # Before — 무응답 (관제는 60초 내내 '정상'으로 보고)
./run.sh diagnose deadlock      # ps -L, 정체 3회 측정
./run.sh case deadlock false    # After  — 계속 정상 가동
```

멈춘 프로세스를 직접 들여다볼 때는 PID 를 이렇게 찾습니다 (2-1 의 주의 참고).

```bash
W=$(pgrep -f "^/home/agent/agent-app/agent-leak-app-arm64$" | tail -1)
ps -p "$W" -o pid,stat,%cpu,%mem,etime,cmd
ps -L -p "$W" -o pid,tid,stat,%cpu,wchan:20,comm
grep -E '^(State|Threads|VmRSS):' /proc/"$W"/status
```

> `run.sh` 의 `case deadlock` 은 `MEMORY_LIMIT=512` 와 `CPU_MAX_OCCUPY=20` 을
> **함께 고정**합니다. 그러지 않으면 메모리 가드가 먼저 터져서 교착을 볼 수 없습니다.
