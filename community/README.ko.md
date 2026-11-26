# 커뮤니티 캐릭터

[English](README.md) | 한국어

사람들이 도트 친구용으로 그린 캐릭터예요. 앱에서 펫을 오른쪽 클릭 → 캐릭터 → **다른 캐릭터 받기…** 에서 골라 **받기**를 누르면 캐릭터 메뉴에 바로 생겨요. 목록과 미리보기는 [README.md 의 Gallery](README.md#gallery) 에 있어요.

## 기본 캐릭터

아래 여섯은 앱에 들어 있어서 따로 받지 않아도 돼요. [`charas/chars.py`](../charas/chars.py) 가 코드로 그려요.

<p align="center"><img src="../docs/media/characters.gif" alt="기본 캐릭터 여섯: 만두, 도토리, 새싹 화분, 구름, 촛불, 이끼돌" width="720"></p>

## 내 캐릭터 올리기

1. [CHARACTERS.ko.md](../CHARACTERS.ko.md) 대로 캐릭터 꾸러미를 그려요. 갤러리에 올리려면 `idle`, `walk`, `work`, `sleep`, `ask`, `fall`(또는 `jump`)은 있어야 하고, 동작을 더 그릴수록 더 생생해져요.
2. 앱에서 먼저 써 봐요. 폴더를 캐릭터 폴더에 넣고 **캐릭터 다시 불러오기**를 눌러요.
3. 이 레포를 포크해서 `community/<이름>/` 으로 폴더를 넣어요. 이름은 `a-z`, `0-9`, `-` 로 2~32자이고, 기본 캐릭터 이름은 못 써요. 풀 리퀘스트 하나에 캐릭터 하나, 그 폴더 밖은 건드리지 않아요.
4. 풀 리퀘스트를 열어요. CI 가 꾸러미를 검사하고 앱으로 읽어 본 뒤 미리보기를 붙여요(실행 결과의 `previews` 아티팩트). 머지되면 CI 가 미리보기를 그리고 갤러리와 앱 목록에 넣어요.

### chara.json

[원래 키](../CHARACTERS.ko.md#charajson)에 세 가지를 더 넣어요.

```json
{
  "name": "Teacup",
  "names": { "en": "Teacup", "ko": "찻잔" },
  "author": "내-github-아이디",
  "license": "CC-BY-4.0",
  "description": "A little teacup that steams while it waits."
}
```

팬아트는 `"based_on": "캐릭터 (작품)"` 도 넣어요.

| 키 | 뜻 |
|---|---|
| `author` | GitHub 아이디(갤러리에 링크로 나와요) |
| `license` | 그림의 라이선스: `CC-BY-4.0`, `CC-BY-SA-4.0`, `CC0-1.0`, `MIT` 중 하나 |
| `description` | 한 줄 소개, 140자 이하(없어도 돼요) |
| `based_on` | 팬아트만: 원작 캐릭터와 작품, 60자 이하. "팬아트 · 원작 …" 으로 나와요 |

### 규칙

- **직접 그려요.** 남의 스프라이트나 그림을 가져오거나 다른 꾸러미 색만 바꾼 건 안 돼요(CI 가 윤곽을 비교해요).
- **팬아트도 받아요.** 직접 그리고 `based_on` 을 적으면 돼요. 원작 캐릭터의 권리는 원작자에게 있고, `license` 는 내가 그린 그림에만 적용돼요.
- 내 꾸러미는 나만 고칠 수 있어요. CI 가 `author` 와 풀 리퀘스트를 연 GitHub 계정이 같은지 봐요.
- 파일은 `chara.json` 과 `<동작>.png` 만(동작 이름은 [CHARACTERS.ko.md](../CHARACTERS.ko.md)). 다른 파일은 안 돼요.
- 칸 크기는 30×32 도트 이하, 모든 동작이 같은 칸 크기, 동작 하나에 16칸까지.
- 파일 하나 64 KB, 꾸러미 전체 512 KB 까지. 도트 그림은 보통 훨씬 작아요.
- 폭력·선정·혐오 내용은 안 돼요.

풀 리퀘스트 전에 직접 검사해 볼 수 있어요.

```bash
python3 scripts/community.py check                    # 파일 이름·크기·chara.json
python3 scripts/community.py check --app bin/DotBuddy # 앱으로 읽어 보기까지(./build.sh 다음에)
```

그림을 못 그려도 [캐릭터 아이디어](https://github.com/doldoldol21/dot-buddy/issues/new?template=character_idea.yml)를 남기면 누군가 그려 줄 수도 있어요.

## 캐릭터 내리기

캐릭터마다 저작권을 저희가 판단할 수 없어서, 요청이 오면 확인하고 내려요. 내 캐릭터나 그림을 쓴 꾸러미, 위 규칙에 어긋나는 꾸러미가 있으면 [신고해](https://github.com/doldoldol21/dot-buddy/issues/new?template=report_character.yml) 주세요. 관리자가 확인하고 갤러리와 앱 목록에서 빼요. 이미 받은 사람의 맥에 있는 꾸러미는 그대로 남아요. 그린 사람이 자기 꾸러미를 내리고 싶을 때도 같은 곳으로 요청하면 돼요.

## 받기는 이렇게 돌아가요

앱은 **다른 캐릭터 받기…** 를 열 때만 이 레포의 `community/index.json` 을 받아요. 받기를 누르면 목록에 적힌 그 꾸러미 파일(`chara.json` 과 PNG)만 받고, 파일마다 크기와 SHA-256 을 목록과 맞춰 본 뒤 캐릭터 폴더에 넣어요. 꾸러미는 그림과 작은 JSON 뿐이고, 직접 넣은 꾸러미와 같은 로더·같은 제한으로 읽어요.

꾸러미마다 그린 사람이 고른 라이선스(`license` 키)를 따르고, 앱 코드는 MIT 예요.
