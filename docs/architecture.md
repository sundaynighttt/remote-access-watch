# Architecture

Remote Access Watch는 권한과 책임을 두 표면으로 나눕니다.

## 상태 앱

`Remote Access Watch.app`은 로그인 사용자 권한으로 실행되는 메뉴 막대 앱입니다. root 권한을 갖지 않으며 `/Library/Application Support/RemoteAccessWatch/status.json`과 로컬 사건 기록만 읽습니다. 자동복구 설정을 임의로 바꾸거나 명령을 실행하지 않습니다.

## 감시 엔진

`io.github.sundaynighttt.remote-access-watch.watchdog` launchd job이 root 권한으로 매분 한 번 실행됩니다. 엔진은 root 소유 정책을 검증한 뒤 아래 순서로 동작합니다.

1. 기본 경로와 인터페이스 활성 상태를 확인합니다.
2. Google과 Cloudflare의 고정 HTTPS 엔드포인트에 제한 시간 프로브를 보냅니다.
3. 인터넷이 정상이면 Chrome Remote Desktop launchd 상태를 확인합니다.
4. 연속 실패 임계값을 넘고 `active` 모드일 때만 허용된 복구를 시도합니다.
5. 민감한 엔드포인트 세부정보와 게이트웨이 주소를 제외한 공개 상태를 원자적으로 기록합니다.

## 복구 제한

Wi-Fi 복구는 현재 기본 경로가 자동 감지된 Wi-Fi 인터페이스이거나 기본 경로 자체가 없을 때만 적용됩니다. Ethernet 등 다른 인터페이스가 기본 경로면 Wi-Fi 프로세스를 재시작하지 않고 해결되지 않은 사건으로 기록합니다.

Chrome Remote Desktop은 인터넷이 정상일 때만 확인하고 재시작합니다. 네트워크 장애 중 원격 호스트까지 동시에 조작하지 않습니다.

모든 사건에는 per-incident와 시간당 재시도 제한이 있습니다. `full_reboot_enabled`는 `false`만 유효하며 다른 값은 정책 검증 단계에서 거부됩니다.

## 파일 경계

| 목적 | 경로 | 기본 권한 |
| --- | --- | --- |
| 앱 | `/Applications/Remote Access Watch.app` | root 소유, 사용자 실행 가능 |
| 엔진 | `/Library/PrivilegedHelperTools/io.github.sundaynighttt.remote-access-watch/watchdog.py` | root 소유 |
| 정책 | `/Library/Application Support/RemoteAccessWatch/policy.json` | root 전용 읽기 |
| 공개 상태 | `/Library/Application Support/RemoteAccessWatch/status.json` | 모든 사용자 읽기 |
| 사건 기록 | `/Library/Application Support/RemoteAccessWatch/incidents/` | 로컬 사용자 읽기 |
| 로그 | `/Library/Logs/RemoteAccessWatch/` | 로컬 파일, 진단 시 본문 제외 |

## 의도적으로 제외한 범위

- 메신저, 이메일 등 외부 알림
- Windows 측 sentinel 또는 다른 컴퓨터의 원격 제어
- Mac 재부팅, 절전 방지, 전원 장애 복구
- Chrome Remote Desktop 설치와 계정 구성
