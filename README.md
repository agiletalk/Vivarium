# Vivarium 🐠

메뉴바에 사는 macOS 앱. 지금 이 순간 돌아가는 AI 코딩 에이전트들을 **살아있는 수족관 생태계**로 보여줍니다. AgentCat처럼 메뉴바에 상주하고, 필요할 때 큰 수족관 창을 엽니다.

각 에이전트 세션은 종이 다른 물고기가 됩니다. 실제로 무슨 일을 하고 있는지에 따라 헤엄치고, 생각 풍선을 띄우고, 작업을 끝내면 먹이를 먹고 자랍니다.

## 무엇을 감지하나

터미널·로그를 안 봐도 지금 어떤 에이전트가 무슨 일을 하는지 한눈에 보입니다. 여러 로컬 소스에서 활동을 읽습니다(모두 로컬 파일/프로세스 — 네트워크 전송 없음):

- **Claude Code** — `~/.claude/projects/**/*.jsonl` 트랜스크립트를 증분 테일링. 도구 사용, 상태, 모델, 서브에이전트 스폰, 테스트 실패까지 읽어 프로젝트별로 물고기에 매핑.
- **Codex CLI** — `~/.codex/sessions/**/rollout-*.jsonl` 롤아웃 파싱.
- **Copilot CLI** — `~/.copilot/session-state/*.jsonl` 세션 파일을 증분 테일링. 도구 실행 시작/완료, 모델, 테스트 판정, 대기 상태까지 추출하는 리치 소스.
- **OpenCode** — 이벤트 소싱된 SQLite 저장소(`~/.local/share/opencode/opencode.db`의 `event`/`event_sequence` 테이블)를 2초 주기로 읽기 전용 폴링. 시퀀스 커서로 신규 이벤트만 소비하는 리치 소스.
- **Gemini CLI** — 기본으로는 트랜스크립트를 남기지 않지만, 설정에서 Gemini 감지를 켜면 로컬 OpenTelemetry 로그(`~/.gemini/settings.json`의 telemetry `outfile`)를 테일링하는 리치 소스가 됩니다. `session.id`로 세션을 나누고 `gemini_cli.config`(세션 시작)·`gemini_cli.tool_call`·`api_response`·`next_speaker_check`에서 세션·도구 활동·모델·턴 완료를 읽습니다. (opt-in · [설정](#설정) 참고)

  > ⚠️ **인증 안내** — Google은 **2026-06-18**부로 표준 `gemini` CLI의 **무료 로그인**(Gemini Code Assist for individuals 및 AI Pro/Ultra OAuth)을 종료하고 [Antigravity](https://antigravity.google)로 이관했습니다. 이제 `gemini` CLI는 **API 키(`GEMINI_API_KEY`)** 또는 조직의 **Code Assist Standard/Enterprise** 인증에서만 동작하며, 그런 세션만 위 텔레메트리 로그를 생성합니다. (Antigravity는 로그 형식이 다른 별개 제품이라 여기서 감지하지 않습니다.)
- **프로세스 스캔** — `ps` 기반 CPU/프로세스 감지. 전용 세션 소스가 없는 **Cursor**(및 텔레메트리를 켜지 않은 Gemini)의 활동 여부(존재)와, 라이브 세션 파일이 잡히기 전 **Copilot 폴백**에 사용. 리치 세션 소스가 있는 프로바이더는 실제 세션이 잡히면 프로세스 스캔에서 자동 억제됩니다.

## 종 & 성격

| 에이전트 | 종 | 이동 성격 |
|---|---|---|
| Claude | 🐋 고래 | 느리고 신중, 큰 회전반경 |
| Codex | 🐙 문어 | 목표 지점으로 직행 |
| Gemini | 🪼 해파리 | 펄스로 부유하는 랜덤 드리프트 |
| Cursor | 🐡 복어 | 통통하게 부유, 중간 속도 |
| OpenCode | 🐬 돌고래 | 넓게 탐색, 빠른 유영 |
| Copilot | 🐢 바다거북 | 느긋하게 유영 |

> Cursor(그리고 텔레메트리를 켜지 않은 Gemini)는 프로세스 스캔 기반이라 **활동 여부(존재)만** 물고기로 표시됩니다. 세부 도구 활동·생각 풍선은 리치 소스(Claude·Codex·Copilot·OpenCode, 그리고 감지를 켠 Gemini)에서만 나타납니다. 위협 시 도망(상어 회피)은 종 구분 없이 공통이며, 종별 크기 변화 연출은 없습니다.

## 생태계 요소

- 💬 **생각 풍선** — "Running tests…", "Editing FishNode.swift" 등 실제 도구 사용에서 생성
- 🍔 **작업 = 먹이** — 턴/작업 완료 시 먹이가 떨어지고 물고기가 먹으러 감. 먹을수록 커짐(최대 1.45배). 실패하면 먹이를 놓침
- 😴 **피로도** — 오래 일하면 느려지고 색이 흐려짐(GPU 셰이더 탈채도). 쉬면 회복
- 🫧 **협업 진주** — 서브에이전트 스폰 시 부모 물고기에서 진주가 이동
- ⚔️ **버그 = 상어** — 테스트 실패 시 상어 등장, 물고기들이 흩어짐. 해결되면 퇴장
- 📈 **산호초 진화** — 누적 완료 작업에 따라 모래→산호→조개→해초→열대어 떼→거대 수족관
- 🌙 **실시간 밤낮** — 벽시계에 맞춰 조명이 새벽/낮/저녁/밤으로 크로스페이드
- 🏆 **업적 & 희귀 물고기** — 황금 물고기(1/1000 확률로 방문), 전설 물고기(작업 50개 완료·실패 10% 미만 시 종 무관 승격 → "Legend of the Deep" 업적)
- 🧠 **Memory Fish** — 상주 물고기는 세션을 넘어 전문분야(Swift/UI/Backend/Test…)를 축적, 몸에 색 줄무늬로 표시

## 설정

메뉴바 아이콘 → Settings에서:

- **프로바이더별 감지 토글** — Claude·Codex·Copilot·OpenCode 감지를 각각 켜고 끔(다음 실행 시 적용)
- **Gemini 감지** — 기본 꺼짐(opt-in). 켜면 `~/.gemini/settings.json`에 로컬 텔레메트리(`enabled`/`target:local`/`otlpEndpoint:""`/`outfile`/`logPrompts:true`)를 기록해 Gemini 활동을 읽을 수 있게 합니다. 기존 `outfile`이 있으면 재사용(다른 소비자와 공존), 다음 실행 시 적용
- **저전력 모드** — 렌더를 30fps로 캡하고 앰비언트 이펙트(버블·갓레이·야간 플랑크톤)를 꺼 GPU/배터리 절감
- **로그인 시 실행** — 로그인 항목 등록(`.app` 번들로 실행될 때만 동작)
- **메뉴바 아이콘 애니메이션** — 에이전트 활동 중 아이콘에 은은한 펄스
- **데모 모드** — 스크립트 데모로 수족관을 채워 미리보기(다음 실행 시 적용)
- **수족관 리셋** — 모든 물고기·누적 메모리·산호 진행도 초기화

## 아키텍처

```
Sources/
├── VivariumCore/    순수 시뮬레이션(Foundation만): 모델, 생태계 엔진(순수 함수 advance),
│                    조향 수학(SteeringMath), 업적, 페르시스턴스, 데모 스크립트
├── VivariumDetect/  감지 레이어: TailReader + FSEvents, Claude/Codex/Copilot 파서 +
│                    OpenCode SQLite · Gemini 텔레메트리 세션 모니터, 프로세스 스캐너,
│                    DetectionCoordinator(→ AsyncStream<AgentEvent>)
└── Vivarium/        실행 타깃: NSStatusItem + NSPopover 앱 셸(AppKit, AppDelegate 소유;
                     MenuBarExtra 미사용), SwiftUI 뷰, SpriteKit 씬
```

- **의미 상태(스토어)와 연속 모션(SpriteKit)을 분리.** 스토어는 적응형 시맨틱 틱(활성 시 2Hz/500ms, 유휴 시 0.2Hz/5s)으로 "누가 무슨 상태인지"만 관리하고, 씬은 60fps로 Reynolds 조향 기반 유영을 그립니다. 프로토타입의 뚝뚝 끊기던 1초 틱 이동 문제를 없앰.
- **전력 효율** — 창이 닫히거나 가려지면 씬을 완전히 정지(0% GPU). 저전력 모드에선 30fps 캡 + 앰비언트 이펙트 제거. 메뉴바 팝오버는 라이브 SpriteView가 아닌 순수 SwiftUI 요약.
- **샌드박스 없음** — `~/.claude`·`~/.codex`·`~/.copilot`·`~/.gemini`(텔레메트리 로그) 및 `~/.local/share/opencode/opencode.db`(SQLite) 읽기와 `ps` 스캔이 필요. TCC 프롬프트나 Full Disk Access 불필요(홈 하위 dot 디렉터리).
- 외부 의존성 0.

## 빌드 & 실행

```bash
./script/build.sh              # dist/Vivarium.app 빌드(릴리스) + 서명 + 실행 (메뉴바에 🐟 등장)
./script/build.sh --build-only # 번들만 빌드
./script/build.sh --debug      # 디버그 구성(네이티브 아치)으로 빌드 + 실행
./script/build.sh --logs       # 실행 + log stream으로 서브시스템 로그 실시간 출력
./script/build.sh --verify     # 격리 데모 실행 → 씬을 PNG로 렌더 검증 (화면 녹화 권한 불필요)
swift test                     # Core/Detect/App 유닛 테스트
```

릴리스 빌드는 유니버설(arm64 + x86_64)이라 Apple Silicon·Intel 양쪽에서 실행되고, 디버그는 빠른 반복을 위해 네이티브 아치로 빌드합니다.

Xcode에서 열려면 `Package.swift`를 열고 `Vivarium` 스킴 실행. 앱은 Dock에 안 뜨고 메뉴바 아이콘으로만 나타납니다.

> **설치(사용자)** — `brew install --cask agiletalk/tap/vivarium` (Homebrew; quarantine 자동 해제). 또는 [Releases](https://github.com/agiletalk/Vivarium/releases)에서 `Vivarium.zip`을 직접 받으세요. 직접 받은 `.app`은 ad-hoc 서명(미공증)이라 "손상되어 열 수 없습니다"가 뜨면 `xattr -dr com.apple.quarantine /Applications/Vivarium.app` 후 실행하세요.

## 표시 규칙 & 상태 저장

물고기는 **해당 에이전트가 실행 중일 때만** 탱크에 나타납니다. 세션이 끝나거나(CLI 종료 → 프로세스 사라짐 감지, ~45초) 프로세스 스캔 에이전트가 멈추면 물고기는 사라집니다. 단, 그 물고기의 **Memory Fish 스탯(성장·전문분야·완료 수)은 휴면(dormant) 보관**되어, 같은 (프로바이더·프로젝트) 에이전트가 다시 실행되면 그대로 복원됩니다.

첫 실행에 상태 파일이 없고 실제 이벤트를 한 번도 감지하지 못하면 **데모 수족관**을 보여주다가, 첫 실제 활동이 잡히면 데모를 종료하고 실제 세션으로 전환합니다.

`~/Library/Application Support/Vivarium/vivarium-state.json` — 휴면 물고기 스탯·업적·산호 스테이지·누적 카운터만 저장(위치·풍선·현재 세션 등 일시 상태와 화면에 보이는 물고기는 저장 안 함). 따라서 앱을 새로 켜면 실행 중인 에이전트가 없는 한 탱크는 비어 있습니다. `schemaVersion`(현재 v1) 기반 호환성 가드 — 상위 버전 파일은 `.vN.backup.json`, 손상 파일은 `.corrupt.json`으로 백업·격리 후 무시합니다(버전 간 변환 로직은 아직 없음).

## 라이선스

MIT — [LICENSE](LICENSE) 참조.
