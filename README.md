# Vivarium 🐠

메뉴바에 사는 macOS 앱. 지금 이 순간 돌아가는 AI 코딩 에이전트들을 **살아있는 수족관 생태계**로 보여줍니다. AgentCat처럼 메뉴바에 상주하고, 필요할 때 큰 수족관 창을 엽니다.

각 에이전트 세션은 종이 다른 물고기가 됩니다. 실제로 무슨 일을 하고 있는지에 따라 헤엄치고, 생각 풍선을 띄우고, 작업을 끝내면 먹이를 먹고 자랍니다.

## 무엇을 감지하나

터미널·로그를 안 봐도 지금 어떤 에이전트가 무슨 일을 하는지 한눈에 보입니다. 3가지 소스에서 활동을 읽습니다(모두 로컬 파일/프로세스 — 네트워크 전송 없음):

- **Claude Code** — `~/.claude/projects/**/*.jsonl` 트랜스크립트를 증분 테일링. 도구 사용, 상태, 모델, 서브에이전트 스폰, 테스트 실패까지 읽어 프로젝트별로 물고기에 매핑.
- **Codex CLI** — `~/.codex/sessions/**/rollout-*.jsonl` 롤아웃 파싱.
- **프로세스 스캔** — `ps` 기반 CPU/프로세스 감지로 세션 파일이 없는 에이전트(Gemini, Cursor, OpenCode, Copilot)의 활동 여부 포착.

## 종 & 성격

| 에이전트 | 종 | 이동 성격 |
|---|---|---|
| Claude | 🐋 고래 | 느리고 신중, 큰 회전반경 |
| Codex | 🐙 문어 | 목표 지점으로 직행 |
| Gemini | 🪼 해파리 | 펄스로 부유하는 랜덤 드리프트 |
| Cursor | 🐡 복어 | 위협 시 팽창 |
| OpenCode | 🐬 돌고래 | 넓게 탐색, 빠른 유영 |
| Copilot | 🐢 바다거북 | 느긋하게 유영 |

## 생태계 요소

- 💬 **생각 풍선** — "Running tests…", "Editing FishNode.swift" 등 실제 도구 사용에서 생성
- 🍔 **작업 = 먹이** — 턴/작업 완료 시 먹이가 떨어지고 물고기가 먹으러 감. 많이 일한 물고기는 커짐. 실패하면 먹이를 놓침
- 😴 **피로도** — 오래 일하면 느려지고 색이 흐려짐(GPU 셰이더 탈채도). 쉬면 회복
- 🫧 **협업 진주** — 서브에이전트 스폰 시 부모 물고기에서 진주가 이동
- ⚔️ **버그 = 상어** — 테스트 실패 시 상어 등장, 물고기들이 흩어짐. 해결되면 퇴장
- 📈 **산호초 진화** — 누적 완료 작업에 따라 모래→산호→조개→해초→열대어 떼→거대 수족관
- 🌙 **실시간 밤낮** — 벽시계에 맞춰 조명이 새벽/낮/저녁/밤으로 크로스페이드
- 🏆 **업적 & 희귀 물고기** — 황금 물고기(1/1000), 전설의 고래
- 🧠 **Memory Fish** — 상주 물고기는 세션을 넘어 전문분야(Swift/UI/Backend/Test…)를 축적, 몸에 색 줄무늬로 표시

## 아키텍처

```
Sources/
├── VivariumCore/    순수 시뮬레이션(Foundation만): 모델, 생태계 엔진(순수 함수 advance),
│                    조향 수학(SteeringMath), 업적, 페르시스턴스, 데모 스크립트
├── VivariumDetect/  감지 레이어: TailReader + FSEvents, Claude/Codex 파서, 프로세스 스캐너,
│                    세션 모니터, DetectionCoordinator(→ AsyncStream<AgentEvent>)
└── Vivarium/        실행 타깃: MenuBarExtra 앱 셸, SwiftUI 뷰, SpriteKit 씬
```

- **의미 상태(스토어)와 연속 모션(SpriteKit)을 분리.** 스토어는 2Hz 시맨틱 틱으로 "누가 무슨 상태인지"만 관리하고, 씬은 60fps로 Reynolds 조향 기반 유영을 그립니다. 프로토타입의 뚝뚝 끊기던 1초 틱 이동 문제를 없앰.
- **전력 효율** — 창이 닫히거나 가려지면 씬을 완전히 정지(0% GPU). 메뉴바 팝오버는 라이브 SpriteView가 아닌 순수 SwiftUI 요약.
- **샌드박스 없음** — `~/.claude`/`~/.codex` 읽기와 `ps` 스캔이 필요. TCC 프롬프트나 Full Disk Access 불필요(홈 하위 dot 디렉터리).
- 외부 의존성 0.

## 빌드 & 실행

```bash
./script/build.sh              # dist/Vivarium.app 빌드 + 서명 + 실행 (메뉴바에 🐟 등장)
./script/build.sh --build-only # 번들만 빌드
./script/build.sh --verify     # 격리 데모 실행 → 씬을 PNG로 렌더 검증 (화면 녹화 권한 불필요)
swift test                     # Core/Detect 유닛 테스트
```

Xcode에서 열려면 `Package.swift`를 열고 `Vivarium` 스킴 실행. 앱은 Dock에 안 뜨고 메뉴바 아이콘으로만 나타납니다.

## 표시 규칙 & 상태 저장

물고기는 **해당 에이전트가 실행 중일 때만** 탱크에 나타납니다. 세션이 끝나거나(CLI 종료 → 프로세스 사라짐 감지, ~45초) 프로세스 스캔 에이전트가 멈추면 물고기는 사라집니다. 단, 그 물고기의 **Memory Fish 스탯(성장·전문분야·완료 수)은 휴면(dormant) 보관**되어, 같은 (프로바이더·프로젝트) 에이전트가 다시 실행되면 그대로 복원됩니다.

`~/Library/Application Support/Vivarium/vivarium-state.json` — 휴면 물고기 스탯·업적·산호 스테이지·누적 카운터만 저장(위치·풍선·현재 세션 등 일시 상태와 화면에 보이는 물고기는 저장 안 함). 따라서 앱을 새로 켜면 실행 중인 에이전트가 없는 한 탱크는 비어 있습니다. `schemaVersion` 기반 마이그레이션.

## 라이선스

MIT — [LICENSE](LICENSE) 참조.
