# LiveContainer

이 앱은 SideStore로 단독 설치해도 되고, [LiveContainer](https://github.com/LiveContainer/LiveContainer) 안에
설치해도 됩니다. LiveContainer를 쓰면 무료 Apple ID의 "사이드로드 앱 3개" 제한 없이 여러 포트 앱을 함께 둘 수 있습니다.

## 데이터 위치
| 실행 환경 | 게임 파일과 세이브가 있는 곳 ('파일' 앱) |
|---|---|
| 단독 설치 | 나의 iPhone › <앱 이름> |
| LiveContainer | LiveContainer › Games › `<PortDataFolder>` |

`PortDataFolder`는 Info.plist에 있는 앱별 이름입니다(예: `AnotherRed`, `MVPlayer`, `RenPyPlayer`).
LiveContainer는 앱별 데이터를 `Data/Application/<UUID>`에 두는데, '파일' 앱에서 찾기 어려워서
LiveContainer 안에서는 위 `Games` 폴더를 씁니다. 판별 방법: `NSHomeDirectory()`가
`^(.*/(Documents|LiveContainer))/Data/Application/<UUID>$` 형태이면 LiveContainer 안이고,
첫 번째 그룹이 LiveContainer의 Documents입니다.

## 설치
1. iloader로 **LiveContainer+SideStore**를 설치합니다.
2. LiveContainer › 오른쪽 위 `+` › 이 앱의 IPA를 고릅니다.
3. 앱을 한 번 실행하면 LiveContainer › Games › `<PortDataFolder>` › `game` 폴더가 생깁니다.
4. PC판 게임 폴더를 그 `game` 폴더에 복사하고(iTunes › 파일 공유 › LiveContainer로도 가능) 앱을 다시 실행합니다.
5. LiveContainer에서 앱을 길게 눌러 홈 화면 바로가기를 만들 수 있습니다.

LiveContainer의 "공유 앱(Shared)" 모드에서는 데이터가 '파일' 앱에 보이지 않는 곳으로 가니 기본 상태로 두세요.
