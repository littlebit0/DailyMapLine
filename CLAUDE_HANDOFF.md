# DailyMapLine — Claude 인수인계

작성 기준: 2026-10-31, Asia/Seoul. 이 문서는 사용자가 본앱 개발을 Claude에게 넘기기 위해 요청한 인수인계다. 현재 구현·확인 범위는 아래에 적은 브라우저 기술 시제품까지다.

## 1. 시작할 때 읽을 사항

- 현재 작업 루트: `/Users/kimhwi/Documents/ChatGPT/DailyMapLine`
- 시제품 루트: `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype`
- Notion 프로젝트: [DailyMapLine](https://app.notion.com/p/409e3d635bfc80c48926d901e149cd3d)
- 먼저 이 문서, 시제품 `README.md`, `검증 결과.md`, Notion 기획안과 전체 문서 안내를 읽는다.
- 사용자는 이제 iOS·Android 본앱 개발로 넘어가려 한다. 모바일 앱 프로젝트와 개발 기술은 아직 선택·구성하지 않았다. 브라우저 시제품을 네이티브 앱 완성으로 보고하지 않는다.
- 사용자가 마지막으로 시제품 수정 결과에 “ㅇㅋ완벽해”라고 답했다. 승인된 모습은 **폐회로 안쪽을 덮고 브랜치 양옆 50m만 드러내는 지도**와 **5배속 영상**이다.
- 인수인계 작성 후 본앱 개발·배포는 이 대화에서 시작하지 않았다. Claude는 사용자와 이어지는 작업 지시에 맞춰 진행하면 된다.

## 2. 최신 결정 — 오래된 문서보다 우선

### 색 걷기

사용자 정정: “폐회로 느낌으로 닫혔다고 그 내부를 전체 색 걷어내라는 말이 아니야. 그냥 브랜치 주변 색만 걷어내.”

따라서 방문 영역은 브랜치 양옆 각각 50m, 총 폭 100m다. 폐회로가 생겨도 내부 전체를 방문한 것으로 표시하지 않는다. 브랜치에서 50m 이내인 내부 가장자리는 드러나지만 그보다 먼 중앙은 계속 덮는다. 여러 브랜치의 실제 버퍼가 겹쳐 내부를 덮는 경우는 별개다.

기존 버그는 Turf 버퍼의 외곽 링만 마스크의 구멍으로 사용하면서 안쪽 빈 영역을 잃은 것이었다. `src/visited.js`의 `createFogMask()`가 내부 링을 다시 덮는 폴리곤으로 보존한다. 회귀 검사가 있으므로 이 처리를 삭제하거나 폐회로 면적 전체를 드러내는 로직으로 바꾸지 않는다.

### 영상 속도

- 과거 기준: 1km당 5초.
- 최신 사용자 요청: “영상 속도가 너무 느려 한번 5배속으로 해봐.”
- 현재 시제품 기준: **1km당 1초**, `VIDEO_SECONDS_PER_KM = 1`.
- 사용자가 수정 결과를 승인했다. 본앱은 현재 승인된 5배속을 출발 기준으로 삼되, 최초 기획 수치와 구분한다.
- 기존 로컬 기획서와 Notion 일부 문서에는 1km당 5초가 남아 있다. 로컬 `prototype/README.md`, `prototype/src/core.js`, `prototype/검증 결과.md`의 후속 수정 항목이 최신이다. Notion의 과거 검증 영상 약 10.54초도 이전 결과다. 문서 동기화 시 과거 결과를 현재 결과처럼 고치지 말고 변경 이력을 구분한다.

## 3. 서비스와 확정된 범위

목적은 자신의 활동 반경을 영상으로 만들어 다른 SNS에 공유하는 서비스다. 친구의 실시간 위치 공유가 핵심 기능은 아니다.

- 대상: iOS·Android, 전 세계 서비스 지향. 전 세계 실제 지도 품질·스토어 출시가 확인된 상태는 아니다.
- 첫 출시 범위: 방문 기록, 방문 지도, 날짜별 영상 생성·저장·공유, 이를 위한 기록 관리.
- **노드**: 기록된 위치 한 점. 노드별 시각을 영구 저장하지 않고 순서와 날짜별 묶음을 유지한다.
- **브랜치**: 연속 노드를 잇는 경로. 지도상의 길을 따라 연결한다. 실제로 길이 없는 곳은 노드 사이를 직접 연결한다.
- 이동 감지는 하되 이동 수단을 도보·자전거·차량으로 분류하지 않는다. 속도 범위를 기준으로 간격을 조정한다.
- 기록은 사용자가 켜고 끈다. 백그라운드에서도 기록하는 것이 본앱의 목표이고, 지도 화면은 앱에서 보고 있을 때 갱신한다.
- 기록과 브랜치는 로컬 저장. 자체 서비스 서버·위치 업로드·계정 동기화는 도입하지 않는다.
- 외부에서 필요한 지역의 지도·경로 데이터를 받는 방향은 허용했지만 데이터 공급자는 아직 정하지 않았다.
- 다른 앱이 얻은 위치를 활용하는 방식은 사용자가 거절했다.
- 월 달력에서 날짜를 골라 기록을 확인·삭제하고 영상을 만든다.
- 백업은 데이터를 압축 파일 하나로 내보내고 가져오는 방향이다.

### 기록 목표 간격

| 측정 속도 | 목표 간격 |
| --- | ---: |
| 7km/h 미만 | 300초 |
| 7km/h 이상~25km/h 미만 | 180초 |
| 25km/h 이상~60km/h 미만 | 120초 |
| 60km/h 이상~80km/h 미만 | 90초 |
| 80km/h 이상 | 60초 |

정지 실험안: 최근 5분간 기준점 반경 100m 이내에 머무르면 노드 기록을 쉬고, 반경 100m 이상 밖의 위치를 연속 2회 받으면 재개한다. 정확한 기준점 유지·위치 오차·재시작 후 상태와 수신 공백 판정은 본앱에서 설계해야 한다. 운영체제가 이 간격과 100m 재개를 보장한다고 표현하지 않는다.

### 날짜 경계

자정 전 마지막 노드 A에서 그날 영상이 끝난다. 다음 날 영상은 A에서 시작해 다음 노드 B로 이동한다. 노드를 중복 생성하지 않고 참조하는 방향이다. 개별 시각이 없어서 자정의 정확한 위치를 복원하지 못하며 다음 날 영상에 자정 이전 일부 이동이 포함될 수 있다. 삭제 시 A를 남길지 완전히 제거할지는 아직 확정하지 않았다.

### 메인 지도와 영상

- 지도 기반은 **MapLibre + OpenStreetMap**으로 정했다. 공급자·경로 엔진·실제 데이터 라이선스는 별도 과제다.
- 메인 지도만 방문하지 않은 곳을 덮는다. 브랜치 양옆 50m가 드러난다.
- 영상에는 색 걷기를 넣지 않는다.
- 영상은 세로 9:16, 날짜를 화면 구석에 작게 표시한다.
- 브랜치 선은 파란색에 얇은 흰색 테두리다. 지도상 길의 방향이 25도 이상 바뀌는 곳에 파란 원과 흰 테두리를 표시한다. 이 표시용 노드는 실제 위치 기록 노드와 구분한다.
- 선이 경로를 따라 전개되고 지도 카메라도 이동을 따라간다. 영상 길이는 이동 거리에 비례한다. 최신 속도는 1km당 1초다.
- 사용자가 영상 생성을 요청하면 로컬에서 만들고 사용자는 기다린다. 생성 전 시작·끝 구간을 제외할 수 있게 하되 원본은 유지하는 방향이다.
- 생성 실패 시 원본 유지와 재시도, 기록 부족 시 이유 안내를 계획했다.

### 축척 실험안

지도 구석의 축척 막대가 대략 1.5cm라는 사용자 설명을 기준으로 삼았다. 브랜치 길이를 화면상 약 1.5cm 이내로 보이게 하는 실험안이다.

| 브랜치 길이 | 목표 축척 |
| --- | ---: |
| 1km 이하 | 1km |
| 1km 초과~1.5km 이하 | 1.5km |
| 1.5km 초과~2km 이하 | 2km |
| 2km 초과~3km 이하 | 3km |
| 3km 초과~4km 이하 | 4km |
| 4km 초과~5km 이하 | 5km |
| 5km 초과~8km 이하 | 8km |
| 8km 초과~12km 이하 | 12km |
| 12km 초과~20km 이하 | 20km |
| 20km 초과 | 최대 30km |

긴 브랜치 구간에서 부드럽게 축소했다가 기본 1km 축척으로 돌아오는 방향이다. 현재 구현은 360 CSS px 너비 화면에서 1.5cm를 약 57 CSS px로 환산하고, 720px 출력에서는 114px 막대로 계산한다. 실제 휴대폰의 물리적 1.5cm를 보장하지 않는다. 시험 브랜치는 모두 짧아서 장거리 확대·축소 영상은 실제로 검증하지 않았다.

## 4. 배터리 및 검증 지시

사용자가 명시적으로 “그건 실측하지 말자 예상치로만 진행해”라고 했다. **배터리와 실제 모바일 백그라운드 기록의 실측은 진행하지 않는다.** 기능·데이터 보존·렌더링·모의 위치 입력 검사는 별개이며 적절하게 진행할 수 있다.

기획서의 하루 약 2.5%포인트 추가 소모는 다음 가정의 산술 시나리오다.

- 아이폰 17 배터리 약 14.35Wh.
- 감지 등에 평균 5mW, 노드 처리당 추가 5J라고 임의 가정.
- 하루 6시간의 속도 구간별 이동으로 노드 174개를 기록한다고 가정.
- 0.12Wh + 약 0.242Wh = 약 0.362Wh → 약 2.5%포인트.

5mW와 5J는 측정값이 아니다. 실측·검증된 예측 범위나 상한으로 인용하지 않는다. 과거 5분 3.3%, 1분 16.7% 역시 임의 입력의 계산 예시이며 현재 앱 성능의 증거가 아니다.

## 5. 현재 구현

브라우저 정적 기술 시제품이다. 네이티브 iOS·Android 앱 프로젝트, 실제 GPS 수집·권한·백그라운드 기능은 없다.

- MapLibre GL JS 6.16.0, Turf buffer 7.4.0.
- 도구: esbuild 0.28.2, playwright-core 1.64.1. `package-lock.json` 있음.
- 작은 OSM 공개 추출물로 지도와 길 그래프를 생성했다. 기여자 메타데이터는 파생 파일에 남기지 않았다.
- 공개 장소를 이용한 합성 노드 5개, 브랜치 4개, 날짜 2026-10-31.
- 길 그래프에서 A*로 최소 거리의 도로망 경로를 찾는다. 직선 연결이 아니지만 실제 이동 복원도 아니다. 이는 시제품의 단순 추정 알고리즘이며 본앱의 경로 선택 규칙을 확정한 것은 아니다.
- 통행 방향·이동 수단·차량 접근 제한·고도는 판단하지 않는다. 입력과 가장 가까운 길 노드의 최대 허용 거리는 시제품에서 80m다.
- 길에서 멀거나 경로가 없으면 오류를 내며, 데이터 부재를 길 부재로 바꿔 직선 연결하지 않는다. 실제 길 부재 확정 후 직접 연결하는 기능은 미구현이다.
- `localStorage` 키: `DailyMapLine.prototype.recording.v1`. 브라우저별 시험 기록이며 본앱 저장 형식은 아니다.
- localhost 개발 프로세스는 로컬 정적 파일만 제공한다. 서비스 백엔드나 위치 업로드 서버가 아니다.
- 영상은 브라우저 지원에 따라 MP4를 우선 사용하고 WebM을 대체 형식으로 사용한다. 이 환경의 Chrome에서 MP4를 확인했다.

## 6. 현재 확인한 결과

- 코어 검사 6개 통과: 길 그래프 연결·왕복, 연결 실패, 속도·축척 경계, 방향각 표시, 길이·버퍼, 폐회로 내부 마스크 회귀 검사.
- 최신 브라우저 결과: 총 2,095.6568m, 목표 약 2.0957초, 실제 MP4 **2.155833초**, 720×1280, 197,548 bytes, 방향 변경 표시 15개.
- 외부 네트워크 요청 0건, 페이지 스크립트 오류 0건. 이미 로컬 데이터가 준비된 상태에서 후속 HTTP 요청을 차단하고도 영상을 생성·다운로드했다.
- 새로고침 후 브라우저 시험 기록 복원 확인.
- 이전에 390px 화면에서 가로 넘침 없이 기록 생성 확인. 해당 모바일 배치 스크린샷은 5배속 변경 이전 기록이다. 이를 모바일 OS 검증으로 보지 않는다.
- 색 걷기 수정 후 브라우저 스크린샷으로 폐회로 중앙이 계속 덮인 것을 확인했다.
- 시제품은 작은 서울 지도만 포함해 영상의 넓은 기본 축척에서 주변이 비어 보인다. 요구한 축척은 바꾸지 않고 한정 범위를 영상에 표시했다.

주변 지도 보완을 시도했지만 Protomaps 메타데이터 요청의 403과 Overpass 요청의 TLS 연결 실패로 완료하지 못했다. 해당 데이터는 결과물에 포함되지 않았다. 전 세계 데이터·비용·영상 이용권은 해결되지 않았다.

## 7. 로컬 경로 전체 안내

### 프로젝트 문서

| 파일 | 절대 경로 |
| --- | --- |
| 이 인수인계 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/CLAUDE_HANDOFF.md` |
| 로컬 기획서 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/서비스 기획서 초안.md` |
| 지도 후보 조사 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/지도 후보 비교.md` |
| 이전 검증 계획 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/지도와 경로 검증 계획.md` |
| 시제품 실행 안내 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/README.md` |
| 시제품 검증 및 후속 수정 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/검증 결과.md` |

### 코드·설정

| 파일 | 절대 경로와 용도 |
| --- | --- |
| 패키지 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/package.json` |
| 잠금 파일 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/package-lock.json` |
| Git 제외 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/.gitignore` |
| 화면·지도·영상 생성 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/src/app.js` |
| 경로·거리·속도·축척 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/src/core.js` |
| 방문 마스크 수정 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/src/visited.js` |
| HTML | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/index.html` |
| 화면 스타일 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/style.css` |
| 합성 기록 입력 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/sample.json` |
| 개발용 정적 파일 제공 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/scripts/serve.mjs` |
| 작은 OSM 데이터 준비 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/scripts/prepare_data.py` |
| 라이선스 고지 생성 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/scripts/notices.mjs` |
| 코어·폐회로 회귀 검사 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/tests/core.test.mjs` |
| 브라우저 생성·저장 검사 | `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/tests/browser.mjs` |

### 데이터·빌드·의존성

- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/data/map.geojson`
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/data/roads.json`
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/data/metadata.json`
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/app.js` — 빌드 생성물, 직접 편집하지 않는다.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/maplibre-gl.css` — 빌드 때 복사.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/maplibre-gl-worker.mjs` — 빌드 때 복사.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/maplibre-gl-shared.mjs` — 빌드 때 복사.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/public/THIRD-PARTY-NOTICES.txt` — 라이선스 고지.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/node_modules/` — 로컬 개발 의존성, Git 제외.

### 영상·화면·증거

- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/DailyMapLine-2026-10-31.mp4` — 최신 5배속.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/visited-map.png` — 최신 폐회로 마스크 수정 화면.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/video-frame.png`
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/video-result.png`
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/browser-result.json` — 최신 브라우저 검사 근거.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/mobile-layout.png` — 이전 작은 화면 확인.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/mobile-layout-result.json`
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/history/baseline-1km-5s/DailyMapLine-2026-10-31.mp4` — 이전 1km당 5초 영상.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/history/baseline-1km-5s/visited-map.png` — 수정 전 버그 화면.
- `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype/outputs/history/baseline-1km-5s/browser-result.json`

`outputs/`도 Git에서 제외된다. Git만 복사하면 영상·증거·의존성이 누락될 수 있다.

## 8. 실행과 재현

```sh
cd /Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype
npm ci
npm run build
npm start
```

브라우저: http://127.0.0.1:4173/ . 인수인계 시점에 HTTP 200을 확인했다. 이후 프로세스가 종료되었을 수 있으므로 접속을 다시 확인하고, 이미 실행 중이면 같은 포트를 중복 실행하지 않는다. `npm ci`는 의존성 재설치가 필요한 경우에만 수행한다.

```sh
cd /Users/kimhwi/Documents/ChatGPT/DailyMapLine/prototype
npm test
npm run test:browser
```

브라우저 검사는 로컬 정적 프로세스가 실행 중이어야 한다. macOS Google Chrome 실행 경로가 테스트에 명시되어 있다.

`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`

검사 출력은 기존 `outputs/` 파일을 덮어쓴다. 현재 승인된 결과를 보존하려면 먼저 해당 파일을 복사한다. 지도 데이터를 다시 받는 `prepare_data.py`는 이미 파생 파일이 있으므로 재현에 필수는 아니다.

환경 확인: Node 22.23.3, npm 10.9.9. Xcode 27.2는 이전 단계에서 확인했지만 모바일 프로젝트를 빌드한 결과는 없다. Flutter·Android adb·Docker 등은 이전 확인에서 PATH에 없었고 현재 설치 상태 전체를 재확인한 것은 아니다. `simctl` 조회에서 설치 시작이 표시되어 중단한 이력이 있으므로 모바일 환경이 준비되었다고 가정하지 않는다.

## 9. Git 상태와 보존

- 저장소: `/Users/kimhwi/Documents/ChatGPT/DailyMapLine/.git`
- 현재 브랜치명: `main`.
- `HEAD` 커밋이 아직 없다. `git rev-parse HEAD`는 실패했다.
- 현재 소스·문서는 미추적 상태이며 커밋·푸시·PR·배포를 하지 않았다.
- `git reset --hard`, `git clean`, 폴더 재생성으로 파일을 잃지 않게 한다.
- 브라우저 시제품 폴더를 그대로 모바일 앱이라고 전제하지 말고, 본앱 기술을 정한 뒤 현재 자료를 보존하면서 별도 하위 폴더를 구성한다.

## 10. 아직 구현하거나 확정하지 않은 사항

1. 모바일 기술 선택과 iOS·Android 앱 프로젝트.
2. 실제 위치 권한, 켜기·끄기, 백그라운드 기록, 위치 오차·속도 필터·정지 재개·공백 처리.
3. 제품용 로컬 저장 형식과 데이터 손상·스키마 이전·동시 저장 보호.
4. 날짜별 달력, 삭제, 경계 노드 A의 보존 정책.
5. 압축 백업, 암호화·파일 손상 확인·복원 충돌·운영체제 자동 백업 정책.
6. 실제 길 부재와 지도 부재의 판단, 통행 방향과 적절한 길 선택, 전 세계 데이터 배포·갱신·비용.
7. 영상 시작·끝 제외, 모바일 영상 생성, 해상도·프레임률, 생성 취소와 저장 실패 처리.
8. 지도·경로·스타일·글꼴의 상업용 사용·영상 공유 조건과 출처 표시.
9. 개인정보처리방침·약관의 실제 사업자 정보, 연락처·시행일, SDK 전송과 신고 항목의 일치, 지역별 출시 요건.
10. 가격·이용 연령·스토어 계정·서명·스크린샷·심사·배포.

지도 공급자 관련 문의 문안은 준비했지만 전송하지 않았다. 계약·결제·계정 생성·법적 문서 시행·외부 배포를 완료했다고 보고하지 않는다.

## 11. 권장 다음 진행

1. 사용자에게 현재 인수인계와 승인된 시제품을 기준으로 이어받았음을 알리고, 프로젝트·Git 상태를 다시 확인한다.
2. 시제품의 폐회로 마스크와 5배속 영상을 보존하고 필요 범위만 재현한다.
3. iOS·Android 구현 기술과 폴더 구조를 정하고 본앱 기본 구조·로컬 저장을 시작한다. 기존 프로토타입은 비교 기준으로 남긴다.
4. 위치 기록·메인 지도·월 달력·영상·데이터 관리 순서로 개발한다. 구현 전에 필요한 사용자 데이터 정책 결정과 지도 공급 의존성은 별도 표시한다.
5. 요구사항 전체 구현 후 적절한 범위를 검증한다. 배터리·실제 백그라운드 기록 실측은 사용자 지시에 따라 제외한다. 수정 후에는 수정 부분과 직접 영향을 받는 범위만 재검증한다.

## 12. 협업 지침

- 사용자에게 한국어로 간결하게 보고한다. 코드 리뷰 제목·지적·요약·영향·검증 한계는 한국어 필수다.
- 사용자가 정한 대상·형태·기준을 임의 대체하지 않는다. 특히 로컬 저장, 노드별 시각 미저장, 폐회로 내부 미방문, 영상의 색 걷기 제외, 최신 5배속을 지킨다.
- 확인된 사실·계획·가정·미검증을 구분한다. 임의 배터리 숫자를 실측치로 바꾸지 않는다.
- Notion의 새로운 작업물은 기존 본문에 계속 덧붙이지 말고 DailyMapLine 아래 **별도 새 페이지**로 작성한다. 같은 주제의 기존 문서를 보완하는 것은 기존 페이지를 읽고 필요한 부분만 수정한다.
- `/human`은 설치된 명령으로 확인되지 않았다. 이전 문서 작성 때 공개 Humanizer 지침을 참고했으며 명령 실행·설치를 주장하지 않았다.
- 이 작업과 무관한 DailyCalendar 프로젝트나 앱·계정은 변경하지 않는다.

## 13. Notion 경로

아래 페이지 목록은 인수인계 시점에 프로젝트 루트를 다시 조회해 확인했다. 개별 페이지의 내용 전체를 이번 인수인계에서 다시 검증한 것은 아니다. 기획 방향 확정과 각 초안·조사·검증 결과의 상태를 구분해서 읽는다.

| 문서 | Notion URL |
| --- | --- |
| 기획안 | https://app.notion.com/p/409e3d635bfc80a0bacfcaf454f69b70 |
| 사용자 흐름 초안 | https://app.notion.com/p/409e3d635bfc80809969f28395372a40 |
| 기능별 요구사항 명세 초안 | https://app.notion.com/p/409e3d635bfc81c2a221e1e201297e62 |
| 화면 구성 및 이동 흐름 초안 | https://app.notion.com/p/409e3d635bfc81f19078f7b28f7c2a1e |
| 기술 구성 및 확인 과제 초안 | https://app.notion.com/p/409e3d635bfc81d78b41e2c8df73a450 |
| 개발 순서 및 완료 기준 초안 | https://app.notion.com/p/409e3d635bfc811c877dce0defdc5472 |
| 지도 및 경로 데이터 공급 검토 | https://app.notion.com/p/409e3d635bfc817d9bdfdbd9eb65ea40 |
| 지도 공급자 비용 및 이용 조건 확인 | https://app.notion.com/p/409e3d635bfc813abba6ff5b903f0ed8 |
| 로컬 데이터 구조 설계 초안 | https://app.notion.com/p/409e3d635bfc81759643ee9dd896e71f |
| 기록 삭제 및 백업 복원 정책 제안 | https://app.notion.com/p/409e3d635bfc81578d37f19d9e56cd81 |
| 화면 디자인 명세 초안 | https://app.notion.com/p/409e3d635bfc814188b2c340c0dae82c |
| 검증 계획 및 결과 기록 | https://app.notion.com/p/409e3d635bfc819298a3d6bc5ab2ddad |
| 개인정보처리방침 초안 | https://app.notion.com/p/409e3d635bfc81ba9854d75c19a009dc |
| 서비스 이용약관 초안 | https://app.notion.com/p/409e3d635bfc8125948edcaebeb3d787 |
| 스토어 출시 자료 초안 | https://app.notion.com/p/409e3d635bfc815380ffdf8a83d24190 |
| 출시 및 운영 계획 초안 | https://app.notion.com/p/409e3d635bfc813d97b0f7239efa117b |
| 전체 문서 안내 및 남은 결정 | https://app.notion.com/p/409e3d635bfc81078ae5e57052c2cbd3 |
| 로컬 기술 시제품 검증 결과 | https://app.notion.com/p/409e3d635bfc81ff9541cd50260d3286 |

## 14. Claude에게 함께 전달할 시작 문구

```text
DailyMapLine 본앱 개발을 이어서 진행해 줘.
먼저 /Users/kimhwi/Documents/ChatGPT/DailyMapLine/CLAUDE_HANDOFF.md를 읽고,
그 안의 Notion 기획·요구사항·기술 문서와 현재 파일을 확인해.
최신 승인 사항은 브랜치 양옆 50m만 드러내고 폐회로 중앙은 계속 덮는 지도,
영상 1km당 1초(이전 대비 5배속)야.
브라우저 시제품과 증거를 보존하면서 iOS·Android 본앱 구성을 시작해.
배터리와 실제 백그라운드 위치 기록은 실측하지 말고 예상과 공식 자료로 다뤄.
구현·검증·기획·라이선스 미확인을 구분하고, 데이터 보존 정책을 임의 확정하지 마.
```


