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

4. **자체 서명 코드사이닝 인증서로 서명 (ad-hoc 아님) — 효과는 TCC 한정**. `build-app.sh` 가 login 키체인의 `CCBar Code Signing` 자체서명 cert 로 서명(`scripts/make-signing-cert.sh` 가 1회 생성·코드사이닝 신뢰등록, 이름으로 조회, 없으면 ad-hoc fallback). codesign DR = `identifier "com.ccbar.menubar" and certificate root = H"<cert>"` — **cdhash 항이 없어** 재빌드/Sparkle 업데이트에도 동일 → **TCC(손쉬운 사용·자동화) 권한이 재빌드에도 유지**. ⚠️ **이건 TCC 한정 효과다. usage 키체인 프롬프트와는 무관** — 그건 함정 #7. (예전 이 줄에 "cert 가 키체인 ACL 도 유지" 라고 적었는데 **틀렸다**. cert 트러스트 스토어 상태는 키체인 trusted-app 매칭과 무관. ACL 덤프로 확인함.) **회사 Developer ID(DONGKUK) 는 쓰지 말 것**(배포본에 회사 신원). Apple Developer Program 미가입 → GitHub 배포 zip 첫 실행 시 Gatekeeper 우회 필요. ad-hoc→cert 전환 시 TCC 1회 재허용.

5. **`generate-appcast.sh` 의 gh-pages 작업은 worktree 안에서만**. 과거 메인 작업트리에서 `git switch --orphan` + `rm -rf build .build` 를 돌려서 사용자의 빌드 산출물을 날린 적 있음. 모든 git 변경은 `$WORKTREE` 안에서. orphan 생성도 detached worktree → `git rm -rf .`(worktree-local).

6. **Swift 6 strict concurrency**. background queue 에서 `MainActor.assumeIsolated` 금지(크래시) → `Task { @MainActor in }`. 전역 var(`kAXTrustedCheckOptionPrompt` 등)는 하드코딩 문자열로 우회.

7. **usage 키체인 "키 접근 허용" 팝업은 자체서명 앱의 구조적 제약 — 코드로 못 없앤다** (며칠 헤맨 뒤 ACL 직접 덤프 + 실측으로 확정). CCBar 가 Claude Code 의 `Claude Code-credentials`(소유자=Claude Code) 항목을 읽을 때, macOS 는 trusted-app ACL 통과 후 **partition list** 로 한 번 더 거른다. partition 은 코드서명 **팀(teamid)** 기준인데 CCBar 는 자체서명·무팀·미공증이라 **partition 에 영구 등록 자체가 불가능**. 실측: 읽기(Decrypt) ACL 을 allow-all 로 풀고(`SecACLSetContents(acl,nil,…)`) partition 까지 비워도(`security set-generic-password-partition-list -S ""`) **비-Apple 바이너리는 여전히 매 읽기마다 프롬프트**(ad-hoc 테스트 바이너리로 확인). 즉 **실시간 읽기 ⟺ 프롬프트 가능**, 둘 다(실시간+무팝업)는 **Apple Developer Program 공증(teamid partition)** 으로만 가능 — 미가입이라 불가. ⚠️ **이미 시도하고 버린 것들**(다시 하지 말 것): cert·신뢰등록(=TCC 용, 무관) / read-only 화(=write-back 용, 무관) / ACL allow-all·partition 비우기(비-Apple 은 여전히 프롬프트) / 앱 안에서 ACL 고치는 "사용량 키체인 접근 허용" 버튼(CCBar 가 partition 게이트에 막혀 `SecKeychainItemSetAccess` -25293 실패 = 닭-달걀) / UI 비활성화+캐시(사용자가 실시간 원해서 거부). **결론: 실시간 동작 유지, 팝업은 macOS 한계로 수용.** 단 **빈도는 최소화**함 — `UsageApiClient` 가 액세스 토큰을 메모리에 캐시(`cachedToken`, 만료 기준 `tokenLeeway`)해서 키체인 읽기(=프롬프트 뜨는 시점)를 매 fetch → **토큰 수명당 1회(~6h)** 로 줄임. usage 는 캐시된 토큰으로 계속 실시간 갱신. ACL 디버깅 패턴만 남겨둠: `SecAccessCopyACLList`/`SecACLCopyContents` 덤프(`/tmp/acl-dump.swift`).

## 동작상 알아둘 것

- **세션 매칭은 hook 의 `ttyPath` 가 진실**. `send-hook.sh` 가 `ps -p $PPID -o tty=` 로 TTY 를 payload 에 주입(`_ccbar_tty`). `SessionStore.applyHookEvent` 가 그걸 `hookProvidedTTY` 로 영구 저장하고, `refreshProcessInfo` Pass 0 가 cwd 매칭보다 우선시킴. 같은 cwd 에 여러 세션(특히 `claude -c` 이어받기)이 있어도 정확히 구분하는 핵심.
- **토스트 필터 2종**: 마지막 user 메시지가 `Base directory for this skill:` 로 시작하면(oh-my-claudecode 자동 루프) 음소거 — race 회피 위해 `lastUserMessageOnDisk` 로 jsonl tail 직접 읽음. Notification 의 `"waiting for your input"`(idle reminder)도 음소거, `"needs your permission"` 만 표시.
- **별명은 per-session only** (cwd 상속 안 함). `claude -c` 는 같은 session_id 를 이어받으므로 별명도 따라옴 — 사용자가 헷갈릴 수 있어 토스트/카드에 iTerm 창 이름을 함께 표시함.

## 작업 규약

- 변경 후 사용자에게 테스트 떠넘기지 말고 빌드 + 로그로 **스스로 검증**한 다음 보고.
- git: 사용자가 요청할 때만 commit/push. 커밋 author 는 `FindingDory0-0 <saleslogis.ai@gmail.com>`.
- 외부에 영향 주는 작업(release 삭제, push, gh release)은 실행 전 확인받기.
