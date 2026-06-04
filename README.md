# CCBar — Claude Code Menu Bar

macOS 메뉴바 앱. 동시에 돌리는 Claude Code 세션 (iTerm2 / Terminal / VS Code 계열 / JetBrains)들을 한 곳에서 보고, 호스트 창으로 점프하고, 응답·승인 알림을 토스트로 받는다.

전체 설계: [DESIGN.md](../../Documents/AI/etc/claude-code-menu-bar/DESIGN.md)

## 설치 (사용자)

**최신 버전 다운로드 → [Releases 페이지](https://github.com/FindingDory0-0/CCBar/releases/latest)** 에서 `CCBar-X.Y.Z.zip`.

1. zip 압축 해제 → `CCBar.app` 을 **`/Applications`** 로 드래그
2. **첫 실행 — Gatekeeper 우회** (자체서명 + 미공증이라 필요):
   - `CCBar.app` **우클릭 → 열기** → 경고창에서 다시 **"열기"**
   - 또는 터미널: `xattr -dr com.apple.quarantine /Applications/CCBar.app`
3. 첫 실행 시 macOS 권한 2개 승인: **손쉬운 사용**(다른 Space/모니터 창으로 점프) / **자동화**(iTerm2·Terminal 활성화)
4. **키체인 접근 허용** — 사용량(5h/7d) 바는 Claude Code 의 `Claude Code-credentials` 키체인 항목을 읽어 그립니다. 첫 실행 때 "CCBar이(가) 'Claude Code-credentials' 키 접근을 허용하고자 합니다" 창이 뜨면 **암호 입력 + "항상 허용"**. 한 번이면 됩니다.
   - 드물게 이 창이 **반복**되면(앱이 Apple 공증 신원이 아니라 생길 수 있음): **키체인 접근.app** → `Claude Code-credentials` 더블클릭 → **접근 제어** 탭 → **"모든 응용 프로그램이 이 항목에 접근하도록 허용"** → 변경 저장. 그러면 더 묻지 않습니다.
5. 이후 새 버전은 **Sparkle 이 자동 업데이트** — 메뉴바 ⚙ → "업데이트 확인" 으로 즉시 점검도 가능

> ⚠️ 반드시 `/Applications` 에 두고 실행하세요. `Downloads` 등 다른 폴더에서 실행하면 "Mac 부팅 시 자동 실행"(SMAppService)과 Sparkle 자동 업데이트가 macOS 에 의해 차단됩니다.

## 빌드 & 실행

```bash
swift test                       # core 모듈 단위 테스트
swift run ccbar-cli list         # 데이터 파이프라인만 CLI 로 확인
swift run ccbar-cli watch        # 실시간 tail

./scripts/build-app.sh           # CCBar.app 번들 (디버그, build/ 에서 실행)
open build/CCBar.app             # 개발용 실행

# /Applications 에 설치하고 거기서 실행 (로그인 자동 실행·자동 업데이트 테스트용)
CCBAR_INSTALL=1 ./scripts/build-app.sh --release
```

## 새 버전 배포 (개발자 전용)

코드 수정 → commit/push 후 **한 줄**:

```bash
./scripts/release.sh 0.2.0 "변경 요약(선택)"
```

이 한 번이 다음을 전부 수행:
1. `CCBAR_VERSION` 으로 `build-app.sh --release` 호출 → ad-hoc 서명된 `CCBar.app` (CFBundleVersion = 마케팅 버전)
2. `ditto -c -k --keepParent --sequesterRsrc` 로 `CCBar-<버전>.zip` 패키징
3. `v<버전>` 태그 push + `gh release create` 로 GitHub Release 에 zip 첨부
4. `scripts/generate-appcast.sh`: 살아있는 모든 release 의 zip 을 받아 **`sign_update` 로 EdDSA 서명** → `appcast.xml` 재생성 → `gh-pages` 브랜치 push

배포 후 기존 사용자는 Sparkle 이 자동으로 새 버전을 받습니다. (직접 시연하려면 낮은 버전을 설치 후 ⚙ → "업데이트 확인": `CCBAR_VERSION=0.1.0 CCBAR_INSTALL=1 ./scripts/build-app.sh --release`)

### 옛 release 정리

```bash
gh release delete v0.1.0 --yes --cleanup-tag --repo FindingDory0-0/CCBar
./scripts/generate-appcast.sh    # 삭제 후 반드시 — appcast 의 죽은 링크 제거
```

> appcast.xml 은 gh-pages 의 정적 파일이라 release 만 지우면 자동 갱신 안 됨. `generate-appcast.sh` 를 꼭 다시 돌려야 0.1.x 죽은 enclosure 가 사라집니다.

### 인프라 (한 번 셋업 완료)
- **appcast 호스팅**: `https://findingdory0-0.github.io/CCBar/appcast.xml` (gh-pages 브랜치, GitHub Pages). repo Settings → Pages 는 활성화 완료.
- **EdDSA 서명**: private 키가 **개발자 Mac Keychain** 에 있음 (`generate_keys` 생성). public 키는 `build-app.sh` 의 `SUPublicEDKey`. ⚠️ private 키 분실 시 자동 업데이트 체인이 끊김 — 사용자가 새 키로 서명된 버전을 수동 재설치해야 함.
- `gh auth login` 필요 (release.sh 가 `gh` CLI 사용).

> **버전 정합 주의**: Sparkle 은 마케팅 버전이 아니라 `CFBundleVersion` 으로 비교한다. `build-app.sh` 가 `CFBundleVersion = CCBAR_VERSION` 으로 맞춰두므로 appcast 의 `sparkle:version` 과 일치. 빌드 카운터/타임스탬프를 쓰면 비교가 꼬여 "이미 최신" 오판이 난다.

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
- [x] **M6.C** — Sparkle 자동 업데이트 (EdDSA 서명, GitHub Pages appcast, 0.1.1→0.1.2 end-to-end 검증)
- [x] **배포 자동화** — `release.sh` 한 줄로 빌드→서명→GitHub Release→appcast 갱신
- [x] **권한 영속성** — ad-hoc 서명 + identifier-pinned designated requirement로 재빌드 시에도 TCC (Accessibility / Apple Events) 권한 유지

## 안 들어간 것

- 프롬프트 템플릿, 비용(USD) 누적 표시 — 사용자가 필요 없다고 결정 (사용량 % 만으로 충분)
- 정식 Apple Developer Program 서명·공증 — ad-hoc 으로 충분, GitHub 배포 전제

## 알아둘 점

- **Hook 등록**: 첫 실행 시 `~/.claude/settings.json` 에 hook 항목 자동 주입 (원본은 `settings.json.ccbar-backup` 으로 백업)
- **send-hook 스크립트 경로**: `~/.claude/ccbar/send-hook.sh` (공백 없는 경로 — `/bin/sh` 파싱 이슈 회피)
- **첫 실행 시 macOS 권한 요청** 2개: Accessibility (AXRaise 로 정확한 창 포커스) / Apple Events (iTerm2 AppleScript)
- **Skill 자동 루프 토스트 음소거**: 마지막 user 메시지가 `Base directory for this skill:` 로 시작하면 (oh-my-claudecode 의 `ralph` / `ULTRAWORK` / `ai-slop-cleaner` 패턴) 그 turn의 토스트는 건너뜀. 자네가 그 세션에 직접 입력하면 그 turn은 정상 발화
