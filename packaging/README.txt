Remote Access Watch __VERSION__
=========================

macOS의 인터넷 연결과 Chrome Remote Desktop 호스트를 확인하고, 허용된 좁은 범위에서만 자동 복구하는 메뉴 막대 앱입니다.

요구 사항
---------
- macOS 13 Ventura 이상
- Apple Silicon 또는 Intel Mac
- Chrome Remote Desktop 호스트가 이미 구성된 사용자 계정
- 설치와 제거 시 관리자 권한

설치
----
먼저 장애를 기록만 하는 observe 모드로 설치하는 것을 권장합니다.

  sudo ./install.sh

상태 앱에서 인터넷과 Chrome Remote Desktop이 정상으로 표시되는 것을 확인한 뒤 자동복구를 켭니다.

  sudo ./install.sh --mode active

상태와 제품 정보
----------------
메뉴 막대의 방패 아이콘에서 "관리 및 제품 정보…"를 선택합니다. 상태 앱을 종료해도 root 감시 엔진은 계속 실행됩니다.

명령줄 진단
-----------
로그 본문을 출력하지 않고 버전, launchd 상태, 공개 상태와 파일 크기만 확인합니다.

  ./diagnose.sh

제거
----
기본 제거는 로그인 자동실행 등록을 해제하고 사건 기록과 로그를 보존합니다.

  sudo ./uninstall.sh

기록까지 삭제하려는 경우에만 아래 옵션을 사용합니다.

  sudo ./uninstall.sh --purge-state

안전 경계
---------
- Mac을 재부팅하거나 Wi-Fi 전원을 토글하지 않습니다.
- 임의 명령을 실행하지 않습니다.
- 외부 메신저나 서버로 상태와 알림을 보내지 않습니다.
- 현재 패키지는 로컬 검증용 ad-hoc 서명입니다. 공개 배포 전에는 Developer ID 서명과 Apple 공증이 필요합니다.
