# Remote Access Watch

> **AI가 24시간 일하는 사무실과 연구실을 위한 원격접속 안전망.**

사무실이나 연구실의 Mac에서 AI 에이전트, 모델 실험, 자동화 작업을 밤낮없이 실행하는 연구자와 개발자를 위한 macOS 메뉴 막대 앱입니다. 인터넷 연결과 Chrome Remote Desktop 호스트를 확인하고, 미리 정한 좁은 범위에서만 자동 복구합니다. 한국어 앱 이름은 **원격접속 지킴이**입니다.

컴퓨터와 인터넷은 정상인데 Chrome Remote Desktop 호스트만 멈추면 외부에서는 컴퓨터 전체가 꺼진 것처럼 보입니다. 결국 누군가 사무실에 직접 방문해 서비스를 다시 시작해야 합니다. Remote Access Watch는 이런 상황을 해당 Mac 안에서 구분하고, 허용된 복구만 수행해 현장 방문의 필요성을 줄이기 위해 만들었습니다.

현재 저장소는 공개 프리뷰 단계입니다. `0.1.0` 패키지는 Developer ID 서명과 Apple 공증을 완료했으며, 별도 깨끗한 Mac 설치 검증을 마칠 때까지 prerelease로 제공합니다.

<!-- project-release-ledger:start -->
## 릴리스 기준과 전체 버전 흐름

> 자동 관리 원장: [`docs/releases/release-ledger.json`](docs/releases/release-ledger.json) · 갱신일: `2026-09-02`

### 현재 기준선

| 기준 | 버전 | 단계 | 상태 | 요약 | 근거 |
| --- | --- | --- | --- | --- | --- |
| 최신 후보<br>`latest_candidate` | **`0.1.0 (1)`** | `external_processed` | `passed` | active 설치 검증과 Developer ID 서명·Apple 공증을 통과하고 공개 GitHub 프리릴리스로 게시한 최초 후보 | [v0.1.0-verification.md](docs/releases/v0.1.0-verification.md)<br>[외부 근거](https://github.com/sundaynighttt/remote-access-watch/releases/tag/v0.1.0) |
| 설치 검증 최신<br>`last_installed_smoke` | **`0.1.0 (1)`** | `external_processed` | `passed` | active 설치 검증과 Developer ID 서명·Apple 공증을 통과하고 공개 GitHub 프리릴리스로 게시한 최초 후보 | [v0.1.0-verification.md](docs/releases/v0.1.0-verification.md)<br>[외부 근거](https://github.com/sundaynighttt/remote-access-watch/releases/tag/v0.1.0) |
| 외부 처리 최신<br>`last_external` | **`0.1.0 (1)`** | `external_processed` | `passed` | active 설치 검증과 Developer ID 서명·Apple 공증을 통과하고 공개 GitHub 프리릴리스로 게시한 최초 후보 | [v0.1.0-verification.md](docs/releases/v0.1.0-verification.md)<br>[외부 근거](https://github.com/sundaynighttt/remote-access-watch/releases/tag/v0.1.0) |

### 전체 버전 흐름

| 순서 | 날짜 | 버전 | 단계 | 상태 | 요약 | 근거 |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | 2026-09-02 | `0.1.0 (1)` | `external_processed` | `passed` | active 설치 검증과 Developer ID 서명·Apple 공증을 통과하고 공개 GitHub 프리릴리스로 게시한 최초 후보 | [v0.1.0-verification.md](docs/releases/v0.1.0-verification.md)<br>[외부 근거](https://github.com/sundaynighttt/remote-access-watch/releases/tag/v0.1.0) |
<!-- project-release-ledger:end -->

## 왜 만들었나요?

AI 연구와 에이전트 운영에서는 컴퓨터가 단순한 개인용 PC가 아니라 **24시간 계속 일하는 연구 장비이자 실행 환경**이 됩니다. 특히 사무실·연구실의 Mac mini나 워크스테이션을 집, 출장지, 다른 도시에서 원격으로 확인하는 경우가 많습니다.

이때 가장 난감한 장애 중 하나가 다음 상황입니다.

1. Mac은 켜져 있고 인터넷도 정상입니다.
2. AI 실험이나 자동화 프로세스도 계속 실행 중일 수 있습니다.
3. 하지만 Chrome Remote Desktop 호스트만 중지되거나 응답하지 않습니다.
4. 외부에서는 원인을 구분할 수 없고 원격으로 다시 접속할 수도 없습니다.
5. 결국 사람이 사무실이나 연구실에 방문해 문제를 해결해야 합니다.

Remote Access Watch는 이 마지막 단계를 줄이기 위한 로컬 안전장치입니다. 같은 Mac에서 인터넷과 원격 호스트를 별도로 확인하고, 연속 실패가 확인됐을 때만 Wi-Fi 관리 프로세스 또는 Chrome Remote Desktop 서비스를 제한적으로 재시작합니다.

이런 환경을 주요 대상으로 합니다.

- AI 에이전트와 자동화 작업을 상시 운영하는 개인 연구자·개발자
- 장시간 학습, 추론, 수집, 평가 작업을 원격으로 확인해야 하는 팀
- 사무실이나 연구실의 Mac을 무인에 가깝게 운영하는 환경
- 야간·주말 장애 때문에 현장 방문 비용이 발생하는 원격 작업 환경

이 제품은 범용 원격관리나 감시 소프트웨어가 아닙니다. 임의 명령 실행이나 Mac 재부팅 대신, **원격접속을 다시 확보하는 데 필요한 최소한의 복구만 수행**하도록 범위를 제한합니다.

## 무엇을 하나요?

- 60초마다 기본 네트워크 경로와 허용된 HTTPS 엔드포인트를 확인합니다.
- Wi-Fi 경로가 연속 실패할 때 `airportd` 프로세스만 제한 횟수 안에서 재시작합니다.
- 인터넷은 정상인데 Chrome Remote Desktop 호스트가 중지되면 해당 launchd 서비스만 재시작합니다.
- 메뉴 막대와 관리 창에서 현재 상태, 모드, 버전, 최근 사건과 설치 위치를 보여줍니다.
- 상태와 사건 기록은 로컬에만 저장하며 외부 메신저나 서버로 보내지 않습니다.

Mac 재부팅, Wi-Fi 전원 토글, 임의 명령 실행은 정책과 코드에서 허용하지 않습니다.

## 요구 사항

- macOS 13 Ventura 이상, Apple Silicon 또는 Intel Mac
- Chrome Remote Desktop이 이미 설치되고 호스트가 구성된 사용자 계정
- 설치와 제거 시 관리자 권한

## 설치와 업데이트

[GitHub Releases](https://github.com/sundaynighttt/remote-access-watch/releases)의 압축 파일을 풀고 터미널에서 실행할 수 있습니다. 로컬 개발 패키지는 다음 명령으로 만듭니다.

```bash
./scripts/package-release.sh
```

릴리스 관리자는 Developer ID 인증서와 `notarytool` 키체인 프로필을 준비한 뒤 아래 명령으로 서명·공증·stapling·최종 압축 검증을 한 번에 수행할 수 있습니다. Apple ID, 앱 전용 암호와 인증서 파일은 저장소에 넣지 않습니다.

```bash
REMOTE_ACCESS_WATCH_SIGN_IDENTITY='Developer ID Application: ...' \
REMOTE_ACCESS_WATCH_NOTARY_PROFILE='remote-access-watch-notary' \
./scripts/notarize-release.sh
```

압축을 푼 폴더에서 기본 안전 모드인 `observe`로 설치합니다. 이 모드는 장애를 감지하고 기록하지만 복구 명령은 실행하지 않습니다.

```bash
sudo ./install.sh
```

실제 자동복구를 켜려면 명시적으로 `active`를 선택합니다.

```bash
sudo ./install.sh --mode active
```

같은 설치 명령으로 업데이트할 수 있습니다. 기존 정책이 현재 schema와 호환되면 설정을 보존하고, 교체 전 파일은 root 전용 백업 폴더에 보관합니다. 설치기는 로그인 자동실행 항목도 현재 `/Applications` 앱 경로로 다시 등록합니다. 설치 자체는 Wi-Fi나 원격 호스트를 재시작하지 않습니다.

## 상태 확인과 진단

메뉴 막대의 방패 아이콘에서 **관리 및 제품 정보…**를 열면 제품의 역할과 현재 상태를 확인할 수 있습니다. 명령줄 진단은 로그 내용을 노출하지 않고 버전, launchd 상태, 공개 상태, 파일 개수와 크기만 출력합니다.

```bash
./diagnose.sh
```

## 제거

기본 제거는 로그인 자동실행 등록, 앱과 감시 엔진을 없애고 로컬 사건 기록과 로그를 보존합니다.

```bash
sudo ./uninstall.sh
```

기록까지 지우려는 경우에만 아래 옵션을 사용합니다.

```bash
sudo ./uninstall.sh --purge-state
```

## 개발

```bash
python3 -m unittest discover -s tests -v
cd app/RemoteAccessWatch && swift test
```

아키텍처와 보안 경계는 [docs/architecture.md](docs/architecture.md), 취약점 제보 범위는 [SECURITY.md](SECURITY.md)를 참고하세요.

## 공개 배포 상태

코드와 패키지는 개인 경로, 외부 메신저, 별도 자동화 런타임에 의존하지 않도록 분리했습니다. `0.1.0` 공개 프리릴리스는 Developer ID 서명, hardened runtime, Apple notarization과 stapling을 완료했습니다. 일반 릴리스 승격 전 남은 배포 게이트는 다음과 같습니다.

- 공증된 최종 ZIP을 깨끗한 macOS 13+ Intel/Apple Silicon 환경에서 설치·업데이트·제거 smoke test
