# CCBar — Claude Code Menu Bar

macOS 메뉴바 앱. 동시에 돌리는 Claude Code 세션 (iTerm2 / Terminal / VS Code 계열 / JetBrains)들을 한 곳에서 보고, 호스트 창으로 점프하고, 응답·승인 알림을 토스트로 받는다.

전체 설계: [DESIGN.md](../../Documents/AI/etc/claude-code-menu-bar/DESIGN.md)

## 빌드 & 실행

```bash
swift test                       # core 모듈 단위 테스트
swift run ccbar-cli list         # 데이터 파이프라인만 CLI 로 확인
swift run ccbar-cli watch        # 실시간 tail

./scripts/build-app.sh           # CCBar.app 번들 (디버그)
open build/CCBar.app             # 실행
```

## 레이아웃

```
Sources/
  CCBarCore/      # 모델 / JSONL 파서 / FSEvents watcher / 프로세스 probe / 사용량 클라이언트 /
                  # 호스트 어댑터 (iTerm2 / Terminal / VSCode fork / JetBrains)
  ccbar-cli/      # 데이터 파이프라인 검증용 CLI (UI 없음)
  ccbar-app/      # SwiftUI MenuBarExtra + 토스트 윈도우 + 환경설정
Tests/
  CCBarCoreTests/
scripts/
  build-app.sh    # SPM 빌드 → .app 번들링 → Sparkle 임베드 → ad-hoc 서명
  make-icon.swift # AppIcon 생성 (SwiftUI ImageRenderer)
```

## 진행 상황

- [x] **M1** — 데이터 파이프라인 (JSONLWatcher / ProcessProbe / SessionStore / CLI)
- [x] **M2** — 메뉴바 UI 골격 + 구독 사용량 표시 (5h / 7d / Opus / Sonnet 바)
- [x] **M3** — Hook 통합 (Stop / Notification / SessionStart / PreToolUse / PostToolUse)
- [x] **M4** — 호스트 어댑터 (iTerm2 + AXRaise / Terminal / VSCode·Cursor·Antigravity / JetBrains / Generic)
- [x] **M5.A** — 새 세션 wizard (iTerm2, 4 모드: 기본 / 대화 이어하기 / 권한 부여 / 권한 부여 · 대화 이어하기)
- [x] **M5.B** — 세션 검색 (별명 / cwd / 마지막 메시지)
- [x] **M6.A** — 로그인 시 자동 실행 (SMAppService)
- [x] **M6.B** — 앱 이름 / 아이콘 확정
- [x] **M6.C** — Sparkle 자동 업데이트
- [x] **권한 영속성** — ad-hoc 서명 + identifier-pinned designated requirement로 재빌드 시에도 TCC (Accessibility / Apple Events) 권한 유지

## 안 들어간 것

- 프롬프트 템플릿, 비용(USD) 누적 표시 — 사용자가 필요 없다고 결정 (사용량 % 만으로 충분)
- 정식 Apple Developer Program 서명·공증 — ad-hoc 으로 충분, GitHub 배포 전제

## 알아둘 점

- **Hook 등록**: 첫 실행 시 `~/.claude/settings.json` 에 hook 항목 자동 주입 (원본은 `settings.json.ccbar-backup` 으로 백업)
- **send-hook 스크립트 경로**: `~/.claude/ccbar/send-hook.sh` (공백 없는 경로 — `/bin/sh` 파싱 이슈 회피)
- **첫 실행 시 macOS 권한 요청** 2개: Accessibility (AXRaise 로 정확한 창 포커스) / Apple Events (iTerm2 AppleScript)
- **Skill 자동 루프 토스트 음소거**: 마지막 user 메시지가 `Base directory for this skill:` 로 시작하면 (oh-my-claudecode 의 `ralph` / `ULTRAWORK` / `ai-slop-cleaner` 패턴) 그 turn의 토스트는 건너뜀. 자네가 그 세션에 직접 입력하면 그 turn은 정상 발화
