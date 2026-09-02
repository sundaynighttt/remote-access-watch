# Security Policy

## Supported versions

아직 공개 릴리스 전이므로 최신 `main`과 최신 릴리스 후보만 보안 수정 대상입니다.

## Reporting a vulnerability

취약점에는 임의 명령 실행 가능성, root 권한 경계 우회, 정책 검증 우회, 진단 출력의 민감정보 노출이 포함됩니다. 공개 이슈를 만들기 전에 GitHub의 private vulnerability reporting 기능을 사용해 주세요. 해당 기능을 사용할 수 없다면 저장소 소유자에게 비공개 채널을 요청하되, 토큰·자격증명·개인 로그를 최초 메시지에 첨부하지 마세요.

## Security boundary

- root launchd job은 고정된 Python 엔진과 root 소유 정책만 실행합니다.
- 네트워크 복구는 실행 파일이 정확히 `/usr/libexec/airportd`인 PID에 `SIGTERM`을 보내는 동작으로 제한됩니다.
- Chrome Remote Desktop 복구는 설정된 사용자 도메인의 `org.chromium.chromoting` launchd label만 재시작합니다.
- 진단 스크립트는 로그 본문, IP 주소, 자격증명을 수집하지 않습니다.
- 이 제품은 침입 탐지, VPN 복구, 전원 복구 또는 원격 명령 실행 도구가 아닙니다.
