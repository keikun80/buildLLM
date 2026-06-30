# Thinking Artifact 기반 코딩 에이전트 재학습(Relearning) 가이드

DeepSeek-R1과 같은 추론(Reasoning) 모델은 대답을 출력하기 전 고유한 생각 과정인 **Thinking Artifact (추론 텍스트)**를 생성합니다. 
이 가이드는 IDE 플러그인(Continue, Cline)에서 발생하는 데이터를 수집하고 정제하여, Qwen 계열 모델을 위한 **`fine_tuning_qwen`**과 DeepSeek 계열 모델을 위한 **`fine_tuning_ds`**로 나누어 재학습(Fine-Tuning)하는 일련의 워크플로우를 다룹니다.

---

## 1. Thinking Artifact 저장 위치 및 데이터 흐름 (Continue vs Cline)

vLLM 자체는 Stateless API 서버이므로 별도의 데이터베이스에 요청/응답 내역을 영구 저장하지 않습니다. 따라서 데이터셋 추출의 핵심 소스는 **클라이언트(개발자 IDE 플러그인)**의 대화 및 작업 로그입니다.

### 1) Continue (Chat 및 자동완성)
Continue 플러그인은 대화 이력과 탭 자동완성 로그를 로컬 PC 내 SQLite 데이터베이스 및 로그 파일에 기록합니다.
*   **대화 이력 DB 위치**: `~/.continue/history/` 디렉토리 내의 SQLite 파일들 (`*.sqlite`)
    *   **스키마**: `history` 테이블 내 `prompt` 필드와 모델의 답변 전체가 기록됩니다. DeepSeek-R1을 연동해 사용했다면 답변에 `<think>...</think>` 태그가 고스란히 저장되어 있습니다.
*   **자동완성 로그 위치**: `~/.continue/dev.log`
    *   **특징**: 자동완성(Autocomplete) 요청 시점의 코드 컨텍스트(Prefix, Suffix), 모델이 제안한 완성 코드(Completion), 개발자가 이를 채택했는지(Accept) 혹은 거절했는지(Reject/Ignore)에 대한 상태가 로그 스트림에 기록됩니다.

### 2) Cline (자율 코딩 에이전트)
Cline은 자율적인 파일 수정 및 CLI 실행을 동반하는 멀티 턴 에이전트이므로, 단순 채팅 로그를 넘어 에이전트가 생각하고 행동한 모든 태스크 내역이 JSON 구조로 저장됩니다.
*   **태스크 이력 디렉토리**:
    *   **Windows**: `%APPDATA%\Code\User\globalStorage\saoudrizwan.claude-dev\tasks`
    *   **macOS**: `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks`
    *   **Linux**: `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks`
*   **구조**: 각 태스크별로 생성되는 `api_conversation_history.json` 파일에 R1 모델이 추론한 생각 태그(`<think>...</think>`), 호출된 도구 명세(예: `read_file`, `write_to_file` 등), 그리고 도구 실행 결과가 시간 순서대로 구조화되어 저장됩니다.

---

## 2. 데이터 수집 및 정제 파이프라인 (Data Pipeline)

로컬 PC들로부터 수집된 원시 로그를 중앙으로 모아 기밀 정보(PII, API Key 등)를 마스킹한 뒤, 각 타겟 모델과 클라이언트에 맞는 포맷으로 변환합니다.

```
[개발자 로컬 로그] (Continue / Cline)
       │
       ▼ (정기 수집 및 PII/기밀 마스킹)
[중앙 전처리 서버]
       │
       ├─► fine_tuning_qwen
       │     ├─ Continue: FIM & Chat 포맷팅 (생각 제거/단축)
       │     └─ Cline: XML 도구 호출 & 지시 최적화 포맷팅
       │
       └─► fine_tuning_ds
             ├─ Continue: <think> 태그 보존 Chat 포맷팅
             └─ Cline: Multi-turn Reasoning & 에이전트 GRPO 포맷팅
```

### 1) Qwen 재학습용 데이터 정제 (`fine_tuning_qwen`)

Qwen-Coder 계열 모델은 추론 전용 모델이 아닌 뛰어난 코드 생성/완성 및 인스트럭션 이행 모델입니다. 따라서 생각 과정을 길게 가져가기보다 정확한 출력을 빠르게 뱉도록 데이터를 가공합니다.

*   **Continue (Chat) 데이터 정제**:
    *   답변 내용 중 `<think>...</think>` 태그가 존재할 경우 이를 **제거**하거나, 매우 핵심적인 주석 형태로 변경하여 질문-답변 쌍만 남깁니다.
    *   **포맷**: ShareGPT 또는 standard Alpaca 포맷으로 변환합니다.
*   **Continue (Autocomplete) 데이터 정제**:
    *   `dev.log`에서 `accepted` 상태인 로그만 필터링하여 FIM(Fill-in-the-Middle) 데이터셋으로 포맷팅합니다.
    *   **포맷**: `<fim_prefix>{코드 앞부분}<fim_suffix>{코드 뒷부분}<fim_middle>{어시스턴트 제안 및 수락된 코드}`
*   **Cline (Agent) 데이터 정제**:
    *   Cline이 제공하는 복잡한 시스템 프롬프트(도구 가이드라인)와 에이전트의 도구 호출 형식을 정합성 있게 매핑합니다.
    *   사용자가 요청한 코딩 작업을 수행하기 위해 Cline의 XML 형식 도구(예: `write_to_file`, `grep_search`)를 호출하는 양식으로 포맷팅합니다.
    *   **포맷**: `{"messages": [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}, {"role": "assistant", "content": "<write_to_file path=\"...\">...</write_to_file>"}]}`

### 2) DeepSeek 재학습용 데이터 정제 (`fine_tuning_ds`)

DeepSeek-R1(또는 Distill 계열)은 생각 과정인 Thinking Artifact의 질이 최종 코드 품질을 좌우합니다. 따라서 생각 과정을 엄격히 보존하고 학습해야 합니다.

*   **Continue (Chat) 데이터 정제**:
    *   모델의 답변에서 `<think>추론 내용</think>최종 답변` 구조를 온전히 보존합니다.
    *   **포맷**: ChatML 또는 DeepSeek R1 전용의 템플릿 구조를 활용하여 생각을 생략 없이 매핑합니다.
*   **Cline (Agent) 데이터 정제**:
    *   멀티 턴 도구 호출 루프 속에서 모델이 오류를 수정해 나가는 과정을 수집합니다.
    *   예컨대 에이전트가 코드를 수정하고 빌드를 돌렸을 때 컴파일 에러(`tool_result`)를 받았다면, 그 다음 턴의 `<think>` 내에서 해당 에러 원인을 분석하고 다시 코드를 수정하는 전체적인 '자가 수정(Self-correction) 루프'를 학습 데이터로 구축합니다.
    *   **포맷**: `<think>{에러 분석 및 복구 계획}</think><write_to_file ...>{수정된 코드}</write_to_file>`

---

## 3. 재학습 (Fine-Tuning) 전략

### 1) Qwen 기반 재학습 (`fine_tuning_qwen`)

Qwen-2.5-Coder(7B, 14B, 32B) 모델을 사용하여 경량화되고 지연 시간이 짧은 사내 코딩 어시스턴트를 만드는 데 집중합니다.

*   **Continue 시나리오**:
    *   **목적**: 사내 프레임워크나 API를 활용한 코드 완성 및 신속한 챗 질의응답 성능 극대화.
    *   **SFT**: 사내 모범 코드 데이터셋과 FIM 데이터셋을 7:3 비율로 혼합하여 단일 에폭 학습을 수행합니다.
    *   **DPO**: 자동완성 로그 중 `accepted`된 코드를 `chosen`으로, `rejected`된 코드(제안되었으나 개발자가 백스페이스로 지우거나 직접 수정한 코드)를 `rejected`로 매핑하여 선호도 학습을 진행해 유해하거나 무관한 코드 생성을 차단합니다.
*   **Cline 시나리오**:
    *   **목적**: 시스템 프롬프트에 정의된 Cline 고유의 도구 사용 양식을 정확히 준수하게 함으로써 도구 파싱 에러(JSON/XML 파싱 에러)를 방지합니다.
    *   **SFT**: 복잡한 다중 도구 호출(Multi-tool calling) 데이터셋을 학습시켜, 엉뚱한 자연어 답변 대신 필요한 도구 태그를 정확히 열고 닫도록 최적화합니다.

### 2) DeepSeek 기반 재학습 (`fine_tuning_ds`)

DeepSeek-R1-Distill-Qwen(또는 Llama) 모델을 기반으로, 복잡한 설계 수준의 코딩 문제를 해결하는 추론 에이전트를 구축합니다.

*   **Continue 시나리오**:
    *   **목적**: 사내 보안 규정이나 설계 아키텍처에 맞추어 "생각하는 순서" 자체를 교정합니다.
    *   **SFT**: 사내 리팩토링 사례나 레거시 마이그레이션 이력을 수집하여, `<think>` 영역 내에서 마이그레이션 대상과 리스크를 미리 식별하고 코드를 생성하도록 학습합니다.
*   **Cline 시나리오**:
    *   **목적**: 에이전트의 루프 횟수를 줄이고, 한 번에 정답 도구를 호출하게 만듭니다. (에이전트 효율화 및 토큰 절감)
    *   **GRPO / DPO (강화학습 및 선호도 학습)**: 
        *   **보상 함수(Reward Function)**: Cline 에이전트가 도구를 호출했을 때 `파싱 성공 여부 (+1.0)`, `빌드/테스트 성공 여부 (+2.0)`, `루프 횟수 감소 (+1.5 - (0.1 * 턴수))` 등을 보상 점수로 설정하여 RL(GRPO)을 수행합니다. 
        *   이를 통해 DeepSeek 모델이 `<think>` 태그 안에서 최적의 실행 경로를 스스로 시뮬레이션하고, 잘못된 파일 수정을 사전에 걸러내도록 유도합니다.

---

## 4. 미세조정 (Fine-Tuning) 실행 가이드

GPU 자원과 학습 효율을 고려하여 **Unsloth**와 **TRL** 라이브러리를 활용한 QLoRA 기법으로 직접 미세조정을 수행합니다.

### 1) `fine_tuning_qwen` SFT 학습 스크립트 예시 (Continue / Cline 통합)

```python
from unsloth import FastLanguageModel
import torch
from trl import SFTTrainer
from transformers import TrainingArguments
from datasets import load_dataset

# 1. 모델 로드 및 LoRA 타겟 지정
max_seq_length = 4096  # Qwen 코드 완성에 적합한 컨텍스트 길이
model, tokenizer = FastLanguageModel.from_pretrained(
    model_name = "Qwen/Qwen2.5-Coder-32B-Instruct",
    max_seq_length = max_seq_length,
    load_in_4bit = True,
)

model = FastLanguageModel.get_peft_model(
    model,
    r = 16,
    target_modules = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    lora_alpha = 32,
    lora_dropout = 0,
    bias = "none",
    use_gradient_checkpointing = "unsloth",
)

# 2. 데이터 포맷팅 (Continue FIM과 Cline Tool Use에 따라 다르게 매핑)
# 데이터셋 파일은 {"messages": [{"role": "system"/"user"/"assistant", "content": "..."}]} 구조
dataset = load_dataset("json", data_files="qwen_relearning_dataset.json", split="train")

def format_prompts(examples):
    # Unsloth 호환용 ChatML 포맷 적용
    texts = []
    for messages in examples["messages"]:
        text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
        texts.append(text)
    return { "text" : texts }

dataset = dataset.map(format_prompts, batched=True)

# 3. 학습 진행
trainer = SFTTrainer(
    model = model,
    tokenizer = tokenizer,
    train_dataset = dataset,
    dataset_text_field = "text",
    max_seq_length = max_seq_length,
    dataset_num_proc = 2,
    packing = True,  # 토큰 패킹을 통해 학습 효율 극대화
    args = TrainingArguments(
        per_device_train_batch_size = 4,
        gradient_accumulation_steps = 4,
        warmup_steps = 10,
        max_steps = 100,
        learning_rate = 2e-4,
        fp16 = not torch.cuda.is_bf16_supported(),
        bf16 = torch.cuda.is_bf16_supported(),
        logging_steps = 5,
        output_dir = "qwen_outputs",
    ),
)

trainer.train()
model.save_pretrained_merged("fine_tuning_qwen_lora", tokenizer, save_method = "lora")
```

### 2) `fine_tuning_ds` 추론 및 도구 호출 정렬 학습 스크립트 예시 (GRPO/DPO 개념)

DeepSeek-R1 Distill 모델은 추론 템플릿(`<think>` 태그)을 유실하지 않는 특수 템플릿 처리가 필요합니다.

```python
from unsloth import FastLanguageModel
import torch
from trl import DPOConfig, DPOTrainer
from datasets import load_dataset

# 1. R1 Distill 모델 로드
max_seq_length = 8192  # 추론 경로 보존을 위해 긴 컨텍스트 사용
model, tokenizer = FastLanguageModel.from_pretrained(
    model_name = "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B",
    max_seq_length = max_seq_length,
    load_in_4bit = True,
)

# R1의 특수 토크나이저 설정 적용
tokenizer.pad_token = tokenizer.eos_token

model = FastLanguageModel.get_peft_model(
    model,
    r = 16,
    target_modules = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    lora_alpha = 32,
    use_gradient_checkpointing = "unsloth",
)

# 2. DPO 선호도 데이터셋 (Accept vs Reject) 로드
# 데이터 구조: {"prompt": "...", "chosen": "<think>...</think>코드", "rejected": "<think>...</think>에러코드"}
dataset = load_dataset("json", data_files="ds_relearning_dpo_dataset.json", split="train")

# 3. DPOTrainer 설정 (생각 과정 손실 방지를 위해 beta 조절)
dpo_trainer = DPOTrainer(
    model = model,
    ref_model = None, # PEFT를 사용하므로 레퍼런스 모델을 None으로 두고 메모리 절약
    args = DPOConfig(
        output_dir = "ds_outputs",
        per_device_train_batch_size = 2,
        gradient_accumulation_steps = 8,
        learning_rate = 5e-5,
        beta = 0.1,  # KL 발산 페널티를 조율하여 <think>의 붕괴를 예방
        max_prompt_length = 2048,
        max_length = max_seq_length,
        fp16 = not torch.cuda.is_bf16_supported(),
        bf16 = torch.cuda.is_bf16_supported(),
        logging_steps = 1,
    ),
    train_dataset = dataset,
    tokenizer = tokenizer,
)

dpo_trainer.train()
model.save_pretrained_merged("fine_tuning_ds_lora", tokenizer, save_method = "lora")
```

---

## 5. 정식 반영 및 배포 주기

1.  **데이터 취합 (매월 말)**: 개발자 PC의 SQLite(`~/.continue/history/`)와 JSON(`saoudrizwan.claude-dev/tasks`) 데이터 중앙 수집 및 PII 기밀 정보 제거 전처리.
2.  **재학습 진행 (분기별 1회)**:
    *   **`fine_tuning_qwen`**: Continue 자동완성과 대화용 어댑터, Cline의 도구 준수율 개선 어댑터 개별 학습.
    *   **`fine_tuning_ds`**: DPO/GRPO를 통해 에이전트 자가 수정 및 효율적 추론 성능 정렬.
3.  **검증**: 기존 코딩 테스트 데이터셋(HumanEval, 사내 전용 테스트)을 활용한 품질 회귀 점검.
4.  **배포**: vLLM 시작 템플릿의 가중치 경로를 신규 학습된 LoRA 가중치 경로로 업데이트하여 롤링 재기동.
