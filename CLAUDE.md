# CCBar — Claude Code 작업 가이드

Claude Code 세션을 관리하는 macOS 메뉴바 앱. SwiftPM, Swift 6 strict concurrency, SwiftUI MenuBarExtra(macOS 14+).

사람용 문서는 `README.md`, 전체 설계는 `~/Documents/AI/etc/claude-code-menu-bar/DESIGN.md`. 이 파일은 **claude 가 코드 작업 시 반복해서 헤매지 않도록** 함정과 규약만 추린 것.

## 빌드 · 실행 · 배포

```bash
swift build --product ccbar-app          # 컴파일만
./scripts/build-app.sh                    # build/CCBar.app (디버그, 개발용)
CCBAR_INSTALL=1 ./scripts/build-app.sh --release   # /Applications 설치 + 실행
./scripts/release.sh 0.2.0 "요약"         # 빌드→서명→GitHub Release→appcast 갱신 (한 줄 배포)
```

검증: 앱은 stderr 를 `/tmp/ccbar-debug.log` 로 redirect 함. hook/포커스/업데이트 동작은 거기 `grep` 으로 확인. 사용자에게 일일이 테스트시키지 말고 로그로 직접 검증할 것.

## 코드 구조

- `Sources/CCBarCore/` — 모델 / `JSONLParser` / `JSONLWatcher`(FSEvents) / `ProcessProbe` / `SessionStore`(actor) / `UsageApiClient` / 호스트 어댑터 / `HookServer`
- `Sources/ccbar-app/` — `AppModel`(@Observable, @MainActor) + SwiftUI 뷰 + 토스트 윈도우
- `scripts/` — `build-app.sh` / `release.sh` / `generate-appcast.sh` / `make-icon.swift`

## 절대 깨면 안 되는 함정들 (전부 실제로 한 번씩 당함)

1. **CFBundleVersion = 마케팅 버전**. Sparkle 은 `CFBundleShortVersionString` 이 아니라 **`CFBundleVersion`** 으로 비교한다. appcast 의 `sparkle:version` 과 반드시 일치해야 함. 빌드 카운터("1")나 타임스탬프를 넣으면 `1 > 0.1.2` 로 오판해서 "이미 최신입니다" 가 뜬다. `build-app.sh` 가 `CCBAR_VERSION` 에서 dash 떼고 그대로 사용 중.

2. **EdDSA 서명 필수**. Sparkle 2 는 `SUPublicEDKey` 없으면 "업데이트 확인" 이 조용히 no-op. private 키는 **개발자 Mac Keychain** 에, public 키는 `build-app.sh` 의 `SUPublicEDKey` 하드코딩. release 시 `generate-appcast.sh` 가 `sign_update` 로 각 zip 서명.

3. **`/Applications` 에서만 동작**. `SMAppService`(로그인 자동 실행)와 Sparkle 인플레이스 업데이트는 `build/` 등 개발 폴더에서 실행하면 macOS 가 거부(SMAppService Code=22). 그 기능 테스트는 `CCBAR_INSTALL=1` 로.

4. **자체 서명 코드사이닝 인증서로 서명 (ad-hoc 아님)**. `build-app.sh` 가 login 키체인의 `CCBar Code Signing` 자체서명 인증서로 서명(`scripts/make-signing-cert.sh` 가 1회 생성, SHA-1 은 머신마다 다르므로 이름으로 조회). codesign 이 내는 DR 은 `identifier "com.ccbar.menubar" and certificate root = H"<cert>"` — **cdhash 항이 없어** 재빌드/Sparkle 업데이트에도 동일. 이게 TCC 뿐 아니라 **키체인 ACL** 신뢰까지 유지하는 핵심. **왜 ad-hoc 을 버렸나**: CCBar 는 Claude Code 의 `Claude Code-credentials` 키체인 항목을 읽어 usage 바를 그리는데, ad-hoc 은 안정 인증서가 없어 키체인이 "항상 허용" 을 (위조 가능한) bundle id 가 아니라 **cdhash 에 핀** → 재빌드/자동업데이트마다 cdhash 가 바뀌어 "키 접근 허용" 프롬프트가 재발했음(TCC 는 관대해서 ad-hoc+identifier DR 로도 유지됐지만 키체인은 아님). 인증서 없는 머신/CI 는 ad-hoc+identifier DR 로 자동 fallback(키체인은 재프롬프트). **회사 Developer ID(DONGKUK) 는 쓰지 말 것** — 배포본에 회사 신원이 박힘. Apple Developer Program 미가입(공증 안 함) → GitHub 배포 zip 은 첫 실행 시 Gatekeeper 우회 필요. 서명 신원을 ad-hoc→cert 로 바꾸면 DR 이 달라져 **TCC·키체인 권한을 마지막으로 1회 재허용**해야 함(이후 영구 유지).

5. **`generate-appcast.sh` 의 gh-pages 작업은 worktree 안에서만**. 과거 메인 작업트리에서 `git switch --orphan` + `rm -rf build .build` 를 돌려서 사용자의 빌드 산출물을 날린 적 있음. 모든 git 변경은 `$WORKTREE` 안에서. orphan 생성도 detached worktree → `git rm -rf .`(worktree-local).

6. **Swift 6 strict concurrency**. background queue 에서 `MainActor.assumeIsolated` 금지(크래시) → `Task { @MainActor in }`. 전역 var(`kAXTrustedCheckOptionPrompt` 등)는 하드코딩 문자열로 우회.

## 동작상 알아둘 것

- **세션 매칭은 hook 의 `ttyPath` 가 진실**. `send-hook.sh` 가 `ps -p $PPID -o tty=` 로 TTY 를 payload 에 주입(`_ccbar_tty`). `SessionStore.applyHookEvent` 가 그걸 `hookProvidedTTY` 로 영구 저장하고, `refreshProcessInfo` Pass 0 가 cwd 매칭보다 우선시킴. 같은 cwd 에 여러 세션(특히 `claude -c` 이어받기)이 있어도 정확히 구분하는 핵심.
- **토스트 필터 2종**: 마지막 user 메시지가 `Base directory for this skill:` 로 시작하면(oh-my-claudecode 자동 루프) 음소거 — race 회피 위해 `lastUserMessageOnDisk` 로 jsonl tail 직접 읽음. Notification 의 `"waiting for your input"`(idle reminder)도 음소거, `"needs your permission"` 만 표시.
- **별명은 per-session only** (cwd 상속 안 함). `claude -c` 는 같은 session_id 를 이어받으므로 별명도 따라옴 — 사용자가 헷갈릴 수 있어 토스트/카드에 iTerm 창 이름을 함께 표시함.

## 작업 규약

- 변경 후 사용자에게 테스트 떠넘기지 말고 빌드 + 로그로 **스스로 검증**한 다음 보고.
- git: 사용자가 요청할 때만 commit/push. 커밋 author 는 `FindingDory0-0 <saleslogis.ai@gmail.com>`.
- 외부에 영향 주는 작업(release 삭제, push, gh release)은 실행 전 확인받기.
