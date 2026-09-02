# Changelog

이 프로젝트는 [Semantic Versioning](https://semver.org/)을 따릅니다.

## [0.1.0] - 2026-09-02

### Added

- 인터넷 및 Chrome Remote Desktop 상태 감시 엔진
- `observe`와 `active` 모드, 횟수 제한이 있는 자동복구
- 제품 역할·현재 상태·안전 경계를 보여주는 macOS 메뉴 막대 앱과 관리 창
- 설치, 업데이트, 진단, 상태 보존형 제거 스크립트
- Apple Silicon/Intel universal 앱 패키징

### Security

- 시스템 전체 재부팅과 Wi-Fi 전원 토글을 금지
- 고정 실행 파일과 허용된 HTTPS 엔드포인트만 사용
- 외부 알림과 개인 운영 환경 의존성 제거
