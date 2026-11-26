# 캐릭터 만들기

[English](CHARACTERS.md) | 한국어

도트 친구에 내 캐릭터를 넣는 방법이에요. 동작 이름으로 PNG 를 넣으면 그 상황에 그 그림을 쓰고, 없는 동작은 가까운 동작이나 자동 동작(기본 그림을 눌리고 늘이고 뒤집기)으로 채워요. 코드는 고치지 않아요.

## 넣는 곳

```
~/Library/Application Support/DotBuddy/charas/
```

펫을 우클릭 → 캐릭터 → **캐릭터 폴더 열기** 로 열고, 넣은 뒤 **캐릭터 다시 불러오기** 를 누르면 바로 메뉴에 나와요(앱을 다시 켜지 않아도 돼요).

남이 보내 준 캐릭터(zip, 폴더, PNG 한 장)는 펫 위에 끌어 놓으면 돼요. 이 폴더로 복사하고 그 캐릭터로 바로 바꿔요. 캐릭터가 쓰는 파일(`chara.json`, 동작 PNG, Codex 펫의 `pet.json` 과 시트)만 복사하고 zip 안의 다른 파일은 넣지 않아요. 이름이 같은 캐릭터가 있으면 휴지통으로 보내요. 터미널에서는 `"$DOTBUDDY" --install-chara <zip|폴더|png>` 예요.

다른 사람이 그린 캐릭터는 캐릭터 → **다른 캐릭터 받기…** 에서 바로 받을 수 있어요. 내 캐릭터가 완성되면 같은 곳에 올려 보세요. [dot-buddy/characters](https://github.com/dot-buddy/characters/blob/main/README.ko.md) 에 방법이 있어요.

## 두 가지 꼴

| 꼴 | 파일 | 동작 |
|---|---|---|
| 낱장 | `charas/<이름>.png` (+ `<이름>.json`) | 그림 한 장. 걷기·점프·잠 같은 동작은 이 그림을 자동으로 움직여 만들어요 |
| 꾸러미 | `charas/<이름>/idle.png`, `walk.png`, … + `chara.json` | 동작마다 직접 그린 그림. 넣은 동작만 그 그림을 쓰고 나머지는 대체 |

## Codex 펫 그대로 쓰기

Codex 앱의 펫 꾸러미(`pet.json` + `spritesheet.webp`)는 고치지 않고 읽어요. 두 곳을 봐요.

- `~/.codex/pets/<이름>/` — Codex 에 넣어 둔 펫(`CODEX_HOME` 을 바꿨으면 그쪽)
- 위 캐릭터 폴더 안의 `<이름>/` — `pet.json` 이 있으면 Codex 펫으로 읽어요

시트는 8칸 × 9줄(한 칸 192×208)이고, 줄마다 이 동작으로 써요. 큰 그림을 키 24점 도트로 줄이고, 칸마다 발을 바닥에 맞춰요(점프 높이는 앱이 옮겨요).

| 줄 | Codex | 도트 친구 |
|---|---|---|
| 0 | idle | `idle` |
| 1 | running-right | `walk` |
| 2 | running-left | (안 씀 — 오른쪽 그림을 뒤집어요) |
| 3 | waving | `wave`·`happy` |
| 4 | jumping | `jump`·`cheer` |
| 5 | failed | `pout`·`dizzy` |
| 6 | waiting | `ask` |
| 7 | running | `sneak` |
| 8 | review | `work` |

줄 순서와 칸 시간은 커뮤니티 문서(hatch-pet `animation-rows.md`) 기준이에요. 반대로 우리 캐릭터를 Codex 펫으로 내보낼 수도 있어요(`spritesheet.png`).

```bash
bin/DotBuddy --export-codex-pet ~/.codex/pets/acorn acorn
```

## 그림 규칙

- 배경은 투명, 칸 하나 = 화소 하나(도트). 반투명 화소는 50% 기준으로 있거나 없거나로 잘라요.
- 오른쪽을 보는 그림으로 그려요. 왼쪽으로 갈 때는 좌우를 뒤집어 그려요.
- 그림 맨 아랫줄이 바닥(발)이에요. 점프·들기 높이는 앱이 옮겨요.
- 칸 하나의 크기는 가로 30 · 세로 32 점까지. 세로 20줄이 넘으면 다른 캐릭터와 키가 맞게 줄여 그려요.
- 꾸러미의 동작 그림은 모두 같은 칸 크기여야 하고, 여러 칸이면 **가로로 이어 붙여요**(`walk.png` = 칸 2개면 가로 2배). 칸 크기가 다른 파일은 건너뛰어요.
- 하트·음표·z·땀·색종이·말풍선·✓ 배지는 앱이 그림 위에 따로 그려요. 그림에 넣지 않아도 돼요.

## chara.json

```json
{
  "name": "보일 이름",
  "names": { "ko": "보일 이름", "en": "Shown name" },
  "frame": [18, 18],
  "height": 18,
  "fps": { "default": 3, "walk": 6, "work": 5 },
  "eyes": [[5, 2, 2, 2], [10, 2, 2, 2]]
}
```

| 키 | 뜻 | 없으면 |
|---|---|---|
| `name` | 메뉴에 보일 이름 | 폴더(파일) 이름 |
| `names` | 화면 언어별 이름(`ko`·`en`) | `name` |
| `frame` | 칸 크기 `[가로, 세로]` | `idle.png` 한 장이 한 칸 |
| `height` | 다른 캐릭터와 크기를 맞출 때 쓰는 몸 키(점). 팔·귀 들 여백은 빼요 | 칸 세로 |
| `fps` | 동작별 초당 칸 수. 한 번 하고 끝나는 동작(점프·반응·하품)은 진행도에 맞춰 칸을 넘겨요 | 6 |
| `eyes` | 깜빡이는 눈 칸 `[x, y, 가로, 세로]` — 자동 깜빡임·웃음·어질 눈에 써요(`idle` 과 낱장에만) | 깜빡임 없음 |

## 동작 이름

가운데 칸이 그 동작을 쓰는 상황이고, 오른쪽 칸은 그 그림이 없을 때 차례로 찾는 대체예요. 맨 끝은 `idle`(그것도 없으면 자동 동작)이에요.

| 이름 | 언제 | 없으면 |
|---|---|---|
| `idle` | 가만히 서 있기(필수 — 칸 크기 기준) | — |
| `blink` | 눈 깜빡임 | idle |
| `walk` | 걷기 | idle |
| `sneak` | 창 뒤에서 살금살금 걸어 나오기 | walk → idle |
| `roll` | 구르기 | walk → idle |
| `work` | 노트북 두드리기(일하는 중) | idle |
| `sleep` | 자기 | idle |
| `yawn` | 하품 | sleep → idle |
| `stretch` | 기지개 | happy → idle |
| `cheer` | 끝났어요(✓ 배지와 함께) | happy → idle |
| `ask` | 질문 기다림 | idle |
| `hum` | 콧노래 | happy → idle |
| `happy` | 기쁨(여러 동작의 대체) | idle |
| `crouch` | 점프 준비(웅크림) — 없으면 기본 그림을 눌러 웅크린다 | idle |
| `jump` | 점프 | idle |
| `land` | 착지 순간 | crouch → idle |
| `fall` | 떨어지기 | jump → idle |
| `drag` | 들려 있기 | fall → jump → idle |
| `pounce` | 커서 덮치기 | jump → idle |
| `stalk` | 덮치기 전 노리기 | idle |
| `dive` | 바닥 속으로 쏙 들어가기(높은 곳·다른 모니터로 갈 때) | jump → idle |
| `climb` | 옆면 오르기 | idle |
| `descend` | 기어 내려가기 | climb → idle |
| `hang` | 매달리기 | climb → idle |
| `sit` | 가장자리에 걸터앉기 | idle |
| `peek` | 내려다보기 | idle |
| `talk` | 말할 때 | idle |
| `petted` | 쓰다듬어질 때 | happy → idle |
| `startle` | 깜짝 | idle |
| `pout` | 삐짐 | idle |
| `party` | 완료 만세 | cheer → happy → idle |
| `hop` | 폴짝 | happy → idle |
| `spin` | 빙글 | idle |
| `heart` | 하트 | happy → idle |
| `squish` | 꾹 눌림 | idle |
| `dizzy` | 어질 | idle |
| `wave` | 손 흔들기 | idle |
| `shy` | 부끄 | idle |
| `star` | 반짝 | happy → idle |
| `flinch` | 움찔 | startle → idle |

## 기본 캐릭터 여섯

만두·도토리·새싹 화분·구름·촛불·이끼돌은 오리지널 디자인이고, 레포의 `charas/chars.py` 가 26×26 꾸러미(굵은 테두리·3단 음영·동작 33가지)로 그려요. `build.sh` 가 이것을 `mandu`·`acorn`·`sprout`·`cloud`·`candle`·`pebble` 로 앱 안(`Contents/Resources/charas`)에 넣고, 앱은 코드로 그린 작은 기본 그림 대신 그걸 써요. 사용자 폴더에 같은 이름 꾸러미를 두면 그쪽이 이겨요(python3 없이 빌드하면 작은 그림으로 나와요).

```bash
python3 -I charas/chars.py <폴더> --sheet   # 여섯 꾸러미 + 전체 견본 _all.png
```

- 모양을 고칠 땐 `chars.py` 의 캐릭터 클래스(`body`·`back`·`front`)를, 동작을 늘릴 땐 `Chara.frames` 를 고쳐요. 다시 `build.sh` 를 돌리면 앱 안의 꾸러미를 새로 그려요. 직접 고친 PNG 는 사용자 폴더에 같은 이름으로 두면 앱 안의 것을 가려요.
- 키(`height`)는 24라 다른 꾸러미와 점 크기가 같아요. 일하는 중엔 앱이 노트북을 얹고, `work` 그림이 손을 그려요.
- 캐릭터마다 혼잣말이 따로 있어요(`Sources/Chatter.swift` 의 `CHARA_LINES`).
- 에러·완료 때 캐릭터마다 다른 효과(구름 비·무지개, 촛불 연기·타오름, 새싹 낙엽·꽃 등)가 2.5초 나와요(`charaFX`). 미리보기: `bin/DotBuddy --fx-sheet /tmp/fx.png`.

## 견본에서 시작하기

기본 캐릭터의 자동 동작을 꾸러미로 뽑아서 고쳐 그리는 게 제일 빨라요.

```bash
bin/DotBuddy --export-pack ~/Library/Application\ Support/DotBuddy/charas/my-acorn acorn   # mandu·acorn·sprout·cloud·candle·pebble
bin/DotBuddy --charas                                   # 불러온 캐릭터와 동작별 칸 수
bin/DotBuddy --motion-sheet /tmp/sheet.png pack:my-acorn  # 동작마다 한 줄씩, 펫이 그리는 그대로 미리보기
```

`--export-pack` 은 `idle`·`blink`·`walk`·`work`·`sleep`·`cheer`·`ask`·`happy`·`jump`·`drag`·`climb`·`hang`·`sit`·`talk`·`startle`·`pout`·`party`·`dizzy`·`wave`·`shy` 를 만들어요. 필요 없는 파일은 지워도 돼요(대체로 내려가요). 다른 폴더에서 시험하려면 `DOTBUDDY_CHARAS=<폴더>` 를 앞에 붙여요.

## 저작권

남이 저작권을 가진 캐릭터는 레포에 넣지 말고 이 폴더에만 두세요. 앱은 이 폴더를 읽기만 하고 어디로도 보내지 않아요.
