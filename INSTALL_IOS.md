# 어나더레드 iOS 설치 가이드

포켓몬스터 어나더레드(PC판)를 아이폰/아이패드에서 실행하는 방법입니다.
앱(엔진)과 게임 파일은 따로 설치합니다.

## 1. 앱 설치 (SideStore)
1. GitHub Actions의 **iOS IPA** 빌드 결과에서 `AnotherRed-unsigned.ipa`를 받습니다.
2. 아이폰에 SideStore(또는 AltStore)가 설치돼 있어야 합니다.
3. IPA를 아이폰으로 옮긴 뒤 SideStore → My Apps → `+` → IPA 선택으로 설치합니다.
   (무료 Apple ID 서명은 7일마다 SideStore에서 새로고침해야 합니다.)

## 2. 게임 파일 넣기
1. 앱을 한 번 실행합니다. "게임 파일이 없습니다" 안내가 뜨고 종료되면서
   '파일' 앱에 **나의 iPhone › Another Red › game** 폴더가 생깁니다.
2. [공식 사이트](https://pokemon.jhcloud.kr/)에서 PC판 게임 zip을 받아 '파일' 앱에서 탭해 압축을 풉니다.
3. 압축이 풀린 폴더(`Pokemon Another Red_PWT_...`)를 통째로 `Another Red › game` 안으로 옮깁니다.
   (폴더 안 내용물만 옮겨도 됩니다. `Game.exe`, `.dll` 파일은 없어도 됩니다.)
4. 앱을 다시 실행합니다.

## 3. 조작
- **터치**: 왼쪽 아래 방향 패드, 오른쪽 아래 C(결정)·X(취소)·Z(메뉴/가방)·D(스페셜),
  위쪽 A(L)·S(R)·Q(배틀 배속). 버튼 글자는 PC 키보드 키와 같습니다.
- **블루투스 컨트롤러**(Xbox, PS DualShock/DualSense, Switch Pro, MFi): 아이폰 설정 › Bluetooth에서
  연결하면 바로 동작하고, 연결돼 있는 동안 화면 버튼은 숨겨집니다.

| 컨트롤러 (Xbox 표기) | 기능 |
|---|---|
| A | 결정 |
| B | 취소 |
| X 또는 Menu | 메뉴·가방 |
| Y 또는 View | 스페셜 (가방 등록 등) |
| LB / RB | L / R |
| RT | 배틀 배속 |
| 십자키 / 왼쪽 스틱 | 이동 |

PS 패드는 ✕=A, ○=B, □=X, △=Y 위치입니다.

## 4. PC와 세이브 주고받기
세이브는 **나의 iPhone › Another Red › Pokemon Another Red** 폴더에 저장됩니다.
PC의 `%APPDATA%\Pokemon Another Red` 폴더와 같은 형식이라 서로 복사해서 이어 할 수 있습니다.
