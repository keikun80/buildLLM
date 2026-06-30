# LLM 코딩 에이전트 PoC 지표 수집 기술 가이드 (metrics_howto.md)

본 문서는 [metrics.md](file:///c:/Users/kokid/Documents/project/buildllm/metrics.md)에 기술된 검증 항목별 실측 데이터를 서버, 로컬 IDE, AWS 인프라 환경에서 추출하기 위한 구체적인 명령어와 파이썬 스크립트, 설정 방법을 수록하고 있습니다.

---

## 1. 준비 단계 지표 수집 방법

### 1) 인프라 프로비저닝 속도 측정
ASG 멤버 인스턴스 런칭 시간과 Nginx 리프레시 로그 간의 타임스탬프 차이를 계산합니다.

1.  **시작 시간 추출**: ASG에서 최초 인스턴스 기동(Launch) 로그 확인
    ```bash
    aws autoscaling describe-scaling-activities \
      --region ap-northeast-2 \
      --auto-scaling-group-name coding-agent-asg \
      --query "Activities[0].StartTime" --output text
    ```
2.  **완료 시간 추출**: Nginx가 가동된 이후 외부 로드 밸런서(ALB)로부터 유입된 최초의 HTTP 200 OK 헬스체크 로그 시간 확인
    ```bash
    # 대상 EC2 내부 로그 조회
    head -n 5 /var/log/nginx/access.log | grep "HTTP/1.1\" 200"
    ```

### 2) 기본 API 응답 지연 시간 및 Latency 측정
`curl` 명령어의 포맷팅 필터를 활용하여 도메인 해석, TCP 핸드셰이크, 첫 바이트 수신(TTFT), 총 통신 시간을 정밀 측정합니다.

*   **실행 명령어**:
    ```bash
    curl -o /dev/null -s -w \
      "Time Lookup (DNS):   %{time_namelookup} s\n\
    Time Connect (TCP):  %{time_connect} s\n\
    Time App Connect:    %{time_appconnect} s\n\
    Time Start Transfer: %{time_starttransfer} s\n\
    Time Total:          %{time_total} s\n" \
      http://<ALB_DNS_DOMAIN_NAME>/
    ```
    *   *Time Start Transfer* 값이 `/v1/models` 등의 API 호출 시 가벼운 헬스체크 기준 50ms 이내여야 통과합니다.

### 3) 고속 로컬 NVMe SSD RAID0 벤치마크
로컬 NVMe SSD 어레이 `/mnt/local-nvme`에 대한 순차적 쓰기 속도를 검증합니다.
*   **실행 명령어**:
    ```bash
    fio --name=write_throughput \
      --directory=/mnt/local-nvme \
      --size=10G \
      --readwrite=write \
      --bs=1M \
      --ioengine=libaio \
      --iodepth=8 \
      --direct=1 \
      --runtime=30 \
      --time_based \
      --group_reporting
    ```
    *   결과값 중 **WRITE: bw=... (MB/s)** 영역이 사내 기획 목표인 3,000MB/s 이상인지 실측합니다.

---

## 2. Phase 1 지표 수집 방법 (Qwen Coder 자동완성)

개발자 로컬에 상주하는 Continue 플러그인 디버그 로그와 대화 이력 데이터베이스에서 통계를 수집합니다.

### 1) Continue SQLite DB에서 수용률(Acceptance Rate) 추출
개발자 PC 내에 존재하는 SQLite DB에서 자동완성 제안 횟수와 수락 횟수의 비중을 계산합니다.

*   **데이터베이스 경로**: `~/.continue/history/` 디렉토리 내 `.sqlite` 파일
*   **수집 스크립트 (Python)**:
    ```python
    import sqlite3
    import glob
    import os

    db_paths = glob.glob(os.path.expanduser("~/.continue/history/*.sqlite"))
    total_suggested = 0
    total_accepted = 0

    for db_path in db_paths:
        try:
            conn = sqlite3.connect(db_path)
            cursor = conn.cursor()
            # Continue 스키마 중 autocomplete의 제안 및 선택 수 확인
            # (플러그인 버전에 따라 테이블 명세가 다를 수 있음)
            cursor.execute("SELECT count(*) FROM autocomplete WHERE accepted = 1")
            accepted = cursor.fetchone()[0]
            cursor.execute("SELECT count(*) FROM autocomplete")
            total = cursor.fetchone()[0]
            
            total_accepted += accepted
            total_suggested += total
            conn.close()
        except Exception:
            continue

    if total_suggested > 0:
        rate = (total_accepted / total_suggested) * 100
        print(f"📊 총 제안 수: {total_suggested}회")
        print(f"📊 수용 수: {total_accepted}회")
        print(f"📈 최종 수용률(Acceptance Rate): {rate:.2f}%")
    else:
        print("수집 가능한 자동완성 로그가 존재하지 않습니다.")
    ```### 2) Continue dev.log에서 Autocomplete (Qwen Coder) TTFT & TPS 추출
*   **로그 경로**: `~/.continue/dev.log`
*   **원리**: Continue는 자동완성(FIM) 요청 시 vLLM(Port 8000)에 통신을 시도하고 완료 후 소요된 시간(ms)과 생성된 토큰 수(completion_tokens)를 로그에 남깁니다. 자동완성은 보통 15토큰 미만의 짧은 코드를 생성하므로, 첫 토큰 응답 속도(TTFT)는 전체 통신 지연 시간(Duration)의 약 70~80% 수준으로 평가하거나 서버사이드 메트릭스를 통해 실측합니다.

*   **수집 스크립트 (Python)**:
    아래 스크립트는 `dev.log` 파일에서 자동완성 동작 관련 로그(소요 시간 및 생성 토큰 수)를 파싱하여 평균 Latency 및 초당 토큰 생성 수(TPS)를 도출합니다.

    ```python
    import os
    import re

    log_path = os.path.expanduser("~/.continue/dev.log")
    if not os.path.exists(log_path):
        print(f"❌ 로그 파일을 찾을 수 없습니다: {log_path}")
        exit(1)

    durations = []
    tokens = []

    # Continue 자동완성 로그 패턴 매칭
    # 예시 포맷: "Autocomplete took 220ms (10 tokens)" 또는 JSON 포맷
    pattern = re.compile(r'(?:Autocomplete|autocomplete).*?took\s*(\d+)ms.*?(\d+)\s*tokens')

    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            match = pattern.search(line)
            if match:
                duration_ms = int(match.group(1))
                token_count = int(match.group(2))
                if token_count > 0:
                    durations.append(duration_ms)
                    tokens.append(token_count)

    if durations:
        avg_latency = sum(durations) / len(durations)
        # 대략적인 TTFT는 네트워크 오버헤드를 포함한 전체 지연의 약 75% 수준으로 추정
        est_ttft = avg_latency * 0.75
        
        # 각 요청별 TPS의 평균 계산
        tps_list = [(tok / (dur / 1000.0)) for tok, dur in zip(tokens, durations)]
        avg_tps = sum(tps_list) / len(tps_list)

        print("=== 💻 Qwen Coder Autocomplete 클라이언트 메트릭스 ===")
        print(f"📊 총 수집 샘플 수: {len(durations)}개")
        print(f"⏱️ 평균 총 소요 시간(Latency): {avg_latency:.1f}ms")
        print(f"⏱️ 추정 첫 토큰 생성 속도(Est. TTFT): {est_ttft:.1f}ms")
        print(f"⚡ 평균 초당 생성 토큰 속도(TPS): {avg_tps:.2f} tokens/s")
    else:
        print("💡 수집된 Autocomplete 성능 로그가 없습니다. IDE 환경에서 자동완성을 먼저 수행해주세요.")
    ```

---

## 3. Phase 2 지표 수집 방법 (DeepSeek R1 및 에이전트)

Cline 에이전트 및 Continue Chat에서 수집되는 대용량 추론 데이터를 집계합니다.

### 1) Continue dev.log에서 Chat (DeepSeek R1) TTFT & TPS 추출
*   **원리**: 개발자가 IDE 대화창을 통해 질문을 던지면 Continue는 대화용 LLM 서버(Port 8001, DeepSeek R1)에 요청을 보내고 완료 상태 및 사용 토큰(Usage) 메트릭스를 출력합니다.
*   **수집 스크립트 (Python)**:
    이 스크립트는 `dev.log` 내에서 DeepSeek R1으로 송신된 채팅 API의 수행 속도와 사용된 총 완성 토큰 수 및 Reasoning(생각) 토큰 수를 파싱합니다.

    ```python
    import os
    import re

    log_path = os.path.expanduser("~/.continue/dev.log")
    
    chat_durations = []
    completion_tokens = []
    reasoning_tokens = []

    # Chat API 통신 로그 패턴 매칭 (Port 8001 대상 요청 탐색)
    # 예시: "POST http://localhost:8001/v1/chat/completions: 200 OK in 4500ms"
    duration_pattern = re.compile(r'POST\s+http://.*?:8001/v1/chat/completions.*?200\s+OK\s+in\s+(\d+)ms')
    # 응답 페이로드 내 토큰 사용량 패턴 매칭
    usage_pattern = re.compile(r'\"completion_tokens\":\s*(\d+).*?\"reasoning_tokens\":\s*(\d+)')

    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        log_content = f.read()

    # 지연시간 정보 추출
    durations_matched = duration_pattern.findall(log_content)
    # 토큰 사용 정보 추출
    usages_matched = usage_pattern.findall(log_content)

    # 매칭 데이터 매핑 계산
    samples = min(len(durations_matched), len(usages_matched))
    for i in range(samples):
        dur = int(durations_matched[i])
        comp = int(usages_matched[i][0])
        reas = int(usages_matched[i][1])
        
        chat_durations.append(dur)
        completion_tokens.append(comp)
        reasoning_tokens.append(reas)

    if chat_durations:
        avg_chat_latency = sum(chat_durations) / len(chat_durations)
        total_comp = sum(completion_tokens)
        total_reas = sum(reasoning_tokens)
        
        # DeepSeek R1의 경우 생각(Reasoning) 완료 후 답변 출력을 시작하므로, 
        # 대략적인 TTFT는 Reasoning 완료 시점인 전체 지연시간의 특정 비중(또는 실측)으로 표현됩니다.
        tps_list = [(c / (d / 1000.0)) for c, d in zip(completion_tokens, chat_durations)]
        avg_chat_tps = sum(tps_list) / len(tps_list)
        
        reasoning_ratio = (total_reas / total_comp) * 100 if total_comp > 0 else 0

        print("=== 🧠 DeepSeek R1 Chat 클라이언트 메트릭스 ===")
        print(f"📊 총 수집 샘플 수: {len(chat_durations)}개")
        print(f"⏱️ 평균 총 소요 시간(Latency): {avg_chat_latency/1000.0:.2f}초")
        print(f"⚡ 평균 초당 생성 토큰 속도(TPS): {avg_chat_tps:.2f} tokens/s")
        print(f"💭 전체 완성 토큰 중 생각(Reasoning) 토큰 비중: {reasoning_ratio:.1f}%")
    else:
        print("💡 수집된 DeepSeek R1 Chat 성능 로그가 없습니다.")
    ```

### 2) 서버사이드 vLLM Prometheus 메트릭스를 통한 실측 기법 (추천)
클라이언트 로그 추정이 아닌, vLLM 호스트 서버가 제공하는 Prometheus 메트릭스 엔드포인트(`/metrics`)를 직접 쿼리하여 네트워크 오버헤드가 제거된 물리 장비 기준의 정확한 **TTFT**와 **TPOT (Time per Output Token)**을 추출하는 방법입니다.

*   **포트 구성**:
    *   Qwen Coder: `http://<EC2_IP>:8000/metrics`
    *   DeepSeek R1: `http://<EC2_IP>:8001/metrics`
*   **실시간 수집용 파이썬 코드 예시**:
    ```python
    import urllib.request
    import re
    import sys

    def fetch_vllm_performance(host, port):
        url = f"http://{host}:{port}/metrics"
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                metrics_data = response.read().decode('utf-8')
            
            # vllm:time_to_first_token_seconds 히스토그램 합계 및 개수 파싱
            ttft_sum = re.search(r'vllm:time_to_first_token_seconds_sum\s+([\d\.\+e\-]+)', metrics_data)
            ttft_count = re.search(r'vllm:time_to_first_token_seconds_count\s+([\d\.\+e\-]+)', metrics_data)
            
            # vllm:time_per_output_token_seconds 히스토그램 합계 및 개수 파싱
            tpot_sum = re.search(r'vllm:time_per_output_token_seconds_sum\s+([\d\.\+e\-]+)', metrics_data)
            tpot_count = re.search(r'vllm:time_per_output_token_seconds_count\s+([\d\.\+e\-]+)', metrics_data)
            
            print(f"=== 🛰️ vLLM Server Performance Metrics ({host}:{port}) ===")
            if ttft_sum and ttft_count and float(ttft_count.group(1)) > 0:
                avg_ttft = (float(ttft_sum.group(1)) / float(ttft_count.group(1))) * 1000.0
                print(f"⏱️ 서버 기준 평균 첫 토큰 응답 속도 (TTFT): {avg_ttft:.2f} ms")
            else:
                print("⏱️ TTFT 데이터 없음 (아직 생성된 추론 요청이 없습니다)")
                
            if tpot_sum and tpot_count and float(tpot_count.group(1)) > 0:
                avg_tpot = (float(tpot_sum.group(1)) / float(tpot_count.group(1))) * 1000.0
                avg_tps = 1000.0 / avg_tpot
                print(f"⚡ 서버 기준 평균 출력 토큰당 지연 (TPOT): {avg_tpot:.2f} ms/token")
                print(f"⚡ 서버 기준 평균 생성 속도 (TPS): {avg_tps:.2f} tokens/s")
            else:
                print("⚡ TPS 데이터 없음")
                
        except Exception as e:
            print(f"❌ 메트릭스 조회 실패 ({host}:{port}): {e}")

    # 실행 예시 (로컬 호스트 기준)
    if __name__ == "__main__":
        print("--- Qwen Coder (Port 8000) 검증 ---")
        fetch_vllm_performance("localhost", "8000")
        print("\n--- DeepSeek R1 (Port 8001) 검증 ---")
        fetch_vllm_performance("localhost", "8001")
    ```

### 3) Cline Task Log 수집 및 성공률 파서
Cline의 전역 스토리지는 태스크별로 하나의 디렉토리와 대화 정보가 담긴 JSON 파일을 남깁니다.

*   **Cline 태스크 로그 경로**: `%APPDATA%\Code\User\globalStorage\saoudrizwan.claude-dev\tasks`
*   **수집 및 파싱 스크립트 (Python)**:
    ```python
    import json
    import glob
    import os

    # OS 환경에 맞춰 경로 설정 (Windows 기준 예시)
    appdata = os.environ.get("APPDATA")
    tasks_path = os.path.join(appdata, "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "tasks", "**", "api_conversation_history.json")

    json_files = glob.glob(tasks_path, recursive=True)
    total_tasks = len(json_files)
    successful_tasks = 0
    total_tool_calls = 0

    for file_path in json_files:
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                history = json.load(f)
                
            # 태스크 최종 성공 여부 판별 (마지막 메시지 분석)
            # 사용자가 태스크 완료를 승인(Accept)했거나 마지막에 완료 응답이 있는 경우
            has_success = False
            for msg in reversed(history):
                if msg.get("role") == "user" and "success" in msg.get("content", "").lower():
                    has_success = True
                    break
                if msg.get("role") == "assistant" and "task complete" in msg.get("content", "").lower():
                    has_success = True
                    
            if has_success:
                successful_tasks += 1
            
            # 도구 사용 횟수 (루프 횟수) 집계
            for msg in history:
                if "tool_use" in str(msg) or "toolCalls" in str(msg):
                    total_tool_calls += 1
                    
        except Exception:
            continue

    print(f"📋 총 에이전트 작업 건수: {total_tasks}건")
    if total_tasks > 0:
        success_rate = (successful_tasks / total_tasks) * 100
        avg_loops = total_tool_calls / total_tasks
        print(f"🏆 자율 해결 성공률: {success_rate:.2f}% (목표 60% 이상)")
        print(f"🔄 작업당 평균 도구 사용 루프 수: {avg_loops:.1f}회 (목표 8회 이하)")
    ```

### 4) DeepSeek R1 Reasoning Tokens 실측
API 요청 시 Stream 응답 필드나 응답 본문의 API 메트릭스를 트래킹합니다.
*   **JSON 응답 파싱 방법**:
    DeepSeek R1 API 응답 스키마 내의 `usage` 필드를 파싱하여 전체 completion_tokens 대비 `reasoning_tokens` 비율을 측정합니다.
    ```json
    "usage": {
      "prompt_tokens": 1205,
      "completion_tokens": 820,
      "total_tokens": 2025,
      "completion_tokens_details": {
        "reasoning_tokens": 450
      }
    }
    ```
    *   **계산**: `Reasoning Token Ratio = 450 / 820 = 54.8%`

---

## 4. 공통 인프라 성능 지표 수집 방법

### 1) GPU 메모리 모니터링 및 OOM 탐색
NVML 라이브러리 및 `nvidia-smi` 쿼리를 주기적으로 수행하여 OOM 발생 여부를 트래킹합니다.

*   **백그라운드 모니터링 스크립트**:
    ```bash
    # 5초 간격으로 타임스탬프, 사용 메모리, 총 메모리 CSV 형태로 로그 기록
    nohup nvidia-smi --query-gpu=timestamp,memory.used,memory.total \
      --format=csv -l 5 > /mnt/local-nvme/gpu_memory_usage.csv 2>&1 &
    ```
*   **OOM 에러 발생 감지 (시스템 로그 분석)**:
    vLLM Docker 컨테이너 및 호스트 커널 로그에서 OOM 또는 CUDA Out of Memory 에러가 검출되었는지 정기 스크리닝을 수행합니다.
    ```bash
    docker logs vllm-qwen 2>&1 | grep -Ei "CUDA out of memory|OOM"
    docker logs vllm-deepseek 2>&1 | grep -Ei "CUDA out of memory|OOM"
    dmesg -T | grep -i "out of memory"
    ```

### 2) AWS Auto Scaling Group 스팟 중단 복구 시간 실측
스팟 중단 경고 발생 시간부터 신규 인스턴스의 타겟 그룹 `Healthy` 전환 상태 변경 기록까지의 시차를 구합니다.

1.  **중단 알림 수신 시간 기록**: 스팟 인스턴스 중단 알림(2분 전 예고)이 AWS EventBridge를 통해 CloudWatch에 도달한 시점 조회.
2.  **신규 로드 밸런서 Target 등록 상태 확인**:
    ```bash
    aws elbv2 describe-target-health \
      --region ap-northeast-2 \
      --target-group-arn <TARGET_GROUP_ARN> \
      --query "TargetHealthDescriptions[?Target.Id=='i-xxxxxxxxxxxxxxxxx'].TargetHealth.State"
    ```
    *   새로 기동된 인스턴스가 `initial`에서 `healthy` 상태로 이행 완료된 시간의 차이를 계산하여 다운타임이 10분 이내를 만족하는지 검토합니다.
