# hanji — 설계 문서

작성일: 2026-06-06
프로젝트명: **hanji** (한지 — 천 년을 가는 한국 전통 종이) · 네이티브 마크다운 에디터

---

## 1. 목적

옵시디언처럼 **플레인 마크다운 보관함(vault)을 편집**하면서, **내가 원하는 integration을 네이티브로 확장**할 수 있는 **오픈소스 macOS 앱**. 핵심 가치 세 가지:

1. **호환** — 기존 markdown vault(폴더 + `.md` + 위키링크 + 첨부)를 그대로 열고/저장. 앱이 데이터를 가두지 않음(파일이 진실의 원천).
2. **네이티브 편집 경험** — Obsidian의 정체성인 **Live Preview**(커서 줄만 원본 마크다운, 나머지는 인라인 렌더)를 SwiftUI + macOS 네이티브 스택(TextKit 2)으로 구현. 한글 IME·맞춤법·접근성을 OS에서 무료로 확보.
3. **확장성** — 호스트는 원시 기능만 제공하고, 모든 기능(내장 포함)은 공개 **확장 SDK** 위에서 구현. 내가 만드는 integration과 내장 기능이 동일한 API를 사용(도그푸딩).

비목표(이 프로젝트가 하지 **않는** 것): Obsidian의 **JS 플러그인 생태계 실행**. 대신 동등 기능을 **네이티브 모듈로 재구현**한다. (자세한 범위는 §13.)

---

## 2. 핵심 결정 (Decision Log)

브레인스토밍에서 확정된 선택. 이후 모든 설계의 전제.

| # | 결정 | 선택 | 근거 |
|---|------|------|------|
| D1 | Obsidian 호환 수준 | **vault 호환 + 독자 네이티브 확장** | 기존 보관함을 쓰되 JS 런타임을 안 들여 네이티브 장점 유지 |
| D2 | 편집 모드 | **점진적 Live Preview** | 요소(heading→bold→link…)를 하나씩 쌓아 v1 범위를 통제하며 Obsidian급으로 성장 |
| D3 | 에디터 엔진 | **TextKit 2 (NSTextView) 네이티브** | "네이티브 스택" 정체성. IME·접근성·찾기 무료. 표면은 프로토콜로 추상화해 폴백 여지 |
| D4 | 확장 1차 사용자 | **외부 데이터 수집 + 커스텀 블록** | 구체적으로 Calendar, Dataview(-lite), Periodic Notes(기본 ON), Templater (Importer는 우선순위 ↓) |
| D5 | 확장 로딩 | **컴파일타임 SDK 먼저** | Swift ABI/서명 이슈 회피. 무빌드 설치(동적 로딩/XPC)는 로드맵 |
| D6 | 마크다운 파서 | **자체 증분 토크나이저(에디터) + swift-markdown(전체 문서)** | §5.1 조사 결과. 증분·Obsidian 확장·마커 숨김에 최적화 + 전체 문서 정확성 확보 |

---

## 3. 플랫폼 / 스택

- **언어/런타임:** Swift 6.3 / macOS 26(Tahoe) 타깃. (개발 머신 확인됨.)
- **UI 셸:** SwiftUI (윈도우/씬/3-페인/설정).
- **에디터 표면:** AppKit `NSTextView` + **TextKit 2**(`NSTextLayoutManager`, `NSTextContentStorage`), SwiftUI엔 `NSViewRepresentable`로 브리지.
- **인라인 커스텀 블록:** `NSTextAttachmentViewProvider`로 본문에 SwiftUI 뷰 호스팅.
- **영속/색인:** SQLite — **GRDB** 래퍼.
- **마크다운 파싱(조사 후 확정 — §5.1):** 에디터 핫패스는 **자체 증분 라인 토크나이저**(범위 매핑·total·Obsidian 확장 직접 처리). 전체 문서(Reading/내보내기)는 **`swift-markdown`(cmark-gfm)**. 키 입력 스타일 적용은 **ChimeHQ Neon**의 TextKit 2 인터페이스 활용(깜빡임 없는 on-keypress 스타일링). 코드블록 *내부* 언어 하이라이트는 후순위로 **tree-sitter(SwiftTreeSitter)**.
- **빌드:** **SPM 우선**(`Package.swift` 멀티 타깃). 풀 Xcode 없이 `swift build`로 가능한지 M0에서 검증(이 머신엔 CLT만 설치). `.app` 번들은 빌드 스크립트로 조립(§9).
- **라이선스:** MIT, 공개 레포.

---

## 4. 아키텍처 개요

프로토콜 지향 SPM 멀티 타깃. **의존성은 아래로만 흐른다(순환 없음).** 플러그인은 `App`/`AppCore`를 절대 import하지 않고 **`ExtensionSDK`에만** 의존 — 이것이 "모든 기능은 확장" 격리의 핵심 보증.

```
┌─────────────────────────────────────────────────────────┐
│  App (SwiftUI)        윈도우/3-페인/커맨드팔레트/설정 UI      │
├─────────────────────────────────────────────────────────┤
│  AppCore / Host       플러그인 레지스트리·생명주기·커맨드·     │
│                       워크스페이스 상태·설정 저장 (SDK 호스트 구현)│
├───────────────┬───────────────────┬─────────────────────┤
│  EditorEngine │   VaultKit        │   ExtensionSDK       │
│  (TextKit 2)  │   (데이터 계층)     │   (공개 API)          │
├───────────────┴───────────────────┴─────────────────────┤
│  MarkdownCore         순수 Swift: 증분 토크나이저/모델       │
└─────────────────────────────────────────────────────────┘

First-party plugins (각자 ExtensionSDK에만 의존):
  PeriodicNotes(기본ON) · Templater · Calendar · DataviewLite · CoreRenderers
  (Importer는 로드맵)
```

**의존 방향:**
`App → AppCore → {EditorEngine, VaultKit, ExtensionSDK}`
`EditorEngine, VaultKit → MarkdownCore`
`ExtensionSDK → MarkdownCore + VaultKit(읽기전용 모델 타입)`
`plugins → ExtensionSDK`

---

## 5. 모듈별 설계

### 5.1 MarkdownCore (순수 Swift, UI 무관)

- **증분 토크나이저:** 편집된 범위 + 뷰포트만 재토큰화. 출력 = **소스 범위가 매핑된 토큰/스팬**. 에디터 데코레이션과 전체 문서 연산 양쪽이 소비.
- **문법 범위:** CommonMark + Obsidian 확장 — 위키링크 `[[ ]]`, 임베드 `![[ ]]`, 태그 `#tag`, 콜아웃 `> [!note]`, frontmatter(YAML), 작업 `- [ ]`.
- **불변식:** 토크나이저는 **total** — 깨진 마크다운에도 throw 금지(평문으로 degrade). → 골든 테스트 용이.
- **파서 선택(조사 결과 / §14 확정):** 에디터 핫패스는 **자체 증분 라인 토크나이저**. 이유 — ① 마크다운은 줄 지향이라 "바뀐 줄 + 영향 블록"만 재스캔하면 증분이 충분히 싸다, ② 위키링크·태그·콜아웃 같은 **Obsidian 확장을 직접** 처리(범용 파서엔 없음), ③ 마커 숨김/노출에 맞춘 **토큰 모양을 우리가 통제**, ④ C 그래머 빌드 의존 없음(SPM-first·Xcode 선택 환경에 유리). 전체 문서 정확성이 필요한 **Reading 모드·내보내기·문서 분석은 `swift-markdown`(cmark-gfm)** 사용(증분 불필요; cmark-gfm은 문자 단위 증분 파싱이 아님). 코드블록 *내부* 언어 하이라이트는 tree-sitter가 강점이라 **후순위 추가**(SwiftTreeSitterLayer의 중첩 언어 지원). **대안:** 자체 토크나이저의 정확성 부담이 커지면 `tree-sitter-markdown`으로 교체 — 단 Obsidian 확장은 별도 오버레이 필요.

### 5.2 VaultKit (데이터 계층, UI 무관)

- **`Vault`** — 열린 폴더. 파일 열거, `.md`/첨부 읽기·쓰기. `.obsidian/` 설정은 **읽기 전용 호환 파싱**(daily-notes 등); 우리 설정은 별도 네임스페이스에 저장해 원본 오염 방지. 쓰기는 **원자적**(temp→rename), **파괴적 변경 전 타임스탬프 백업** 내장.
- **`FileWatcher`** — FSEvents 기반. 외부 변경(다른 앱/git/동기화) 감지 → 디바운스 후 이벤트. 버퍼 dirty + 외부 변경 동시 → **충돌 인지 리로드**(덮어쓰기 금지, 사용자 선택).
- **`Note` 모델** — `path`, `frontmatter`, `body` + 파생값(links/tags/tasks/headings; MarkdownCore가 산출).
- **`MetadataIndex`** — 백링크·태그·Dataview·Calendar·글로벌 검색이 공유하는 **공용 기판**. **GRDB(SQLite)** 영속화. 파일 변경 시 **해당 노트만 증분 재인덱싱**. **파생 캐시** — 손상/삭제 시 파일에서 전체 재빌드(데이터 손실 불가).

  스키마(개략):
  ```
  notes(path PK, title, mtime, created, frontmatter_json)
  links(src_path, dst_target, kind)      -- wikilink | embed | markdown
  tags(path, tag)
  tasks(path, line, status, text, due)
  headings(path, level, text, line)
  notes_fts(path, content)               -- 글로벌 검색용 FTS5 가상 테이블 (v1 포함)
  ```
- **Query 엔진 (Dataview-lite)** — 두 층:
  1. **타입드 쿼리 API**(Swift): `index.notes(NoteQuery(from: .tag("#daily"), where:…, sort:…, group:…))` → 결과셋. 관련 노트 인덱스 변경 시 **자동 재실행**(Combine/AsyncStream 퍼블리셔).
  2. **텍스트 DQL 서브셋**: ` ```dataview ` 블록의 `LIST/TABLE FROM #tag WHERE … SORT …` 일부를 파싱해 1번으로 변환. (전체 Dataview/인라인 DQL/JS는 범위 밖.)
- **글로벌 검색:** `notes_fts`(FTS5) 기반 전문 검색 + 파일명/헤딩 매칭. v1 포함(M3).

### 5.3 EditorEngine (TextKit 2)

- **`MarkdownTextView`** — `NSTextView` 서브클래스(TextKit 2). 한글 marked text·맞춤법·찾기·접근성은 NSTextView가 네이티브 처리.
- **데코레이션 파이프라인(Live Preview의 심장):**
  1. 편집/선택 변경 → MarkdownCore가 **바뀐 범위 + 뷰포트**만 증분 토큰화.
  2. **순수 함수** `decorations(tokens, selection, viewport) -> DecorationSet`. 출력 = ①스타일 런(헤딩 크기·볼드 등) ②**숨길 마커 런**(`**`,`#`,`[[`,`]]`) ③블록 첨부 런. **NSTextView와 분리 → UI 없이 골든 테스트.**
  3. **커서 인지 노출:** 커서가 노드의 enclosing 줄/블록 안이면 마커 노출, 벗어나면 숨김.
  4. `DecorationSet`을 `NSTextLayoutManager`에 적용.
- **스타일 적용 계층(조사 결과):** NSTextStorage(TextKit 1/2)는 "텍스트 변경이 충분히 처리돼 스타일을 입혀도 되는 시점"을 네이티브로 알려주지 않아 **깜빡임 없는 on-keypress 하이라이트가 까다로운** 알려진 함정이 있음. **ChimeHQ Neon**의 `TextLayoutManagerSystemInterface`(TextKit 2)가 이 생명주기를 해결하므로 채택/참조. Neon은 스타일 소스와 무관한 "콘텐츠 기반 스타일링"이라 **우리 토크나이저를 스타일 소스로 그대로 연결** 가능.
- **커스텀 블록 = 인라인 SwiftUI 뷰:** 펜스드 코드블록/임베드/이미지/콜아웃/Dataview 표를 `NSTextAttachmentViewProvider`로 본문에 첨부. 프로바이더가 `RendererRegistry`에 "언어 X 누가 렌더?" 질의 → 해당 `CodeBlockRenderer` 호출.
- **점진 구현 = 데코레이터 플러그인:** 각 요소(heading→bold/italic→inline code→link/wikilink→list/task→quote/callout→codeblock→image→frontmatter)가 파이프라인에 꽂히는 개별 데코레이터.
- **`EditorSurface` 프로토콜:** 앱은 NSTextView가 아니라 이 프로토콜과 대화 → 특정 요소가 TextKit 2로 정 안 풀리면 그 표면만 교체 가능한 **헤지**.
- **성능:** 뷰포트 기반(`NSTextViewportLayoutController`) — 바뀐+보이는 범위만 재토큰화/재데코.

### 5.4 ExtensionSDK (공개 API)

플러그인과 호스트의 계약. **5개 표면**(①~⑤; ④는 노트 생명주기+템플릿을 함께 묶음)과 플러그인 생명주기. (시그니처는 방향성 스케치.)

```swift
public protocol Plugin {
    static var id: String { get }                 // "io.hanji.calendar"
    init()
    func activate(host: PluginHost) throws
    func deactivate()
}

// 호스트가 플러그인에 주는 능력(capability) 묶음 — 능력 범위 한정
public protocol PluginHost {
    var vault: VaultReading { get }               // 보관함 읽기
    var index: MetadataQuerying { get }           // ② 색인 조회
    var commands: CommandRegistry { get }         // ③ 커맨드
    var ui: UIRegistry { get }                     // ③ 사이드바/패널
    var renderers: RendererRegistry { get }        // ① 코드블록 렌더러
    var lifecycle: NoteLifecycle { get }           // ④ 노트 생명주기
    var templates: TemplateRegistry { get }        // ④ 템플릿 함수
    var importers: ImporterRegistry { get }        // ⑤ 임포터 (표면만 v1; 구현 로드맵)
    func settingsStore(for pluginID: String) -> SettingsStore   // 네임스페이스 설정
}

// ① 커스텀 블록
public protocol CodeBlockRenderer {
    var language: String { get }                   // "mermaid", "dataview"
    func makeView(source: String, context: BlockContext) -> AnyView
}

// ② 쿼리 (변경 시 자동 갱신)
public protocol MetadataQuerying {
    func notes(_ q: NoteQuery) -> AnyPublisher<[NoteRef], Never>
    func backlinks(to: NoteRef) -> [NoteRef]
    func search(_ text: String) -> [SearchHit]     // 글로벌 검색(FTS)
}

// ③ 커맨드 & UI
public struct Command { public let id, title: String; public let run: (CommandContext) -> Void }
public protocol CommandRegistry { func register(_ c: Command) }
public protocol UIRegistry {
    func addSidebarView(id: String, placement: SidebarPlacement, _ make: @escaping () -> AnyView)
}

// ④ 노트 생명주기 & 템플릿
public protocol NoteLifecycle { func onCreate(_ handler: @escaping (NewNoteContext) -> Void) }
public protocol TemplateRegistry { func register(_ fn: TemplateFunction) }
public protocol TemplateFunction { var name: String { get }; func evaluate(_ args: [String], _ ctx: TemplateContext) -> String }

// ⑤ 임포터 (SDK 표면은 v1에 정의, 구현은 로드맵)
public protocol Importer {
    var id, displayName: String { get }
    func canImport(_ url: URL) -> Bool
    func run(from url: URL, into vault: VaultWriting) throws -> ImportSummary
}
```

### 5.5 AppCore / Host (내부)

ExtensionSDK 호스트 구현체. 플러그인 레지스트리·생명주기(activate/deactivate), 커맨드 레지스트리, 워크스페이스/레이아웃 상태, **네임스페이스 설정 저장**(영속), VaultKit+EditorEngine+플러그인 배선. SDK를 플러그인에 *제공*만 함(내부 비공개).

### 5.6 App (SwiftUI 셸)

- **3-페인 레이아웃:** 좌(파일 탐색기/검색) · 중(에디터 탭·분할) · 우(사이드바: 백링크·캘린더 등 플러그인 기여).
- **커맨드 팔레트(⌘P):** CommandRegistry의 모든 커맨드.
- **퀵 스위처:** 노트 빠른 이동.
- **글로벌 검색 UI:** FTS 결과 + 파일명/헤딩.
- **설정 UI:** 코어 + 플러그인별 설정(SettingsStore 기반).
- 얇게 — 로직은 AppCore/하위 모듈에 위임.

### 5.7 First-party 플러그인 (SDK 도그푸딩)

각자 ExtensionSDK에만 의존하는 별도 타깃.

- **PeriodicNotes** (기본 ON) — ④ 생명주기·템플릿 + ③ 커맨드. 일/주/월/년 노트 생성·열기.
- **Templater** — ④ 템플릿. 날짜·동적 삽입·간단 치환(코어 토큰부터; 풀 스크립팅은 범위 밖).
- **Calendar** — ③ 사이드바 패널 + ② 쿼리. periodic note 네비게이션.
- **DataviewLite** — ① 커스텀 블록 + ② 쿼리. `LIST/TABLE` 서브셋.
- **CoreRenderers** — ① mermaid·이미지·콜아웃 등 기본 렌더러.
- **Importer** *(로드맵, 우선순위 ↓)* — ⑤ 임포터. 이미 Obsidian 사용 중이라 v1 제외. SDK의 ⑤ 표면은 정의해 두되 구현은 후순위.

---

## 6. 데이터 흐름

**편집 1회:** ⌨️ 타이핑 → (EditorEngine 데코) → 💾 디바운스 자동 저장 → VaultKit 원자적 쓰기 → FS워처 확인 → 🗂️ 해당 노트만 증분 재인덱싱 → 👁️ 구독 중인 뷰(백링크·Dataview·Calendar·검색) 자동 재렌더.

**쿼리(예: `dataview` 블록):** CodeBlockRenderer가 MetadataQuerying으로 질의 → SwiftUI 표 반환 → 관련 노트 인덱스 변경 시 퍼블리셔가 재실행 → 표 갱신.

**외부 편집:** 다른 앱/git/동기화가 파일 변경 → FS워처 감지 → 색인 갱신 → 뷰 갱신. (버퍼 dirty면 충돌 인지 리로드.)

---

## 7. 에러 처리

- **파일시스템:** 파일이 진실의 원천. 원자적 쓰기(temp→rename) + 파괴적 변경 전 백업. 외부 편집 충돌 → 덮어쓰기 대신 알림/선택.
- **색인:** 파생 캐시. 손상/버전 불일치 → 파일에서 전체 재빌드(데이터 손실 0).
- **플러그인:** 오작동 플러그인이 앱을 죽이지 않게 — 호스트 호출 지점에 **에러 경계**. 렌더러가 throw하면 **인라인 에러 카드**로 대체(에디터 생존). 느린 작업은 메인 액터 밖. (완전 격리는 XPC 로드맵.)
- **토크나이저:** total — 깨진 마크다운에 throw 금지, 평문으로 degrade.

---

## 8. 테스트 전략

- **MarkdownCore:** 순수 단위/골든 테스트(입력→토큰/스팬). **증분 편집 테스트**(편집 → 영향 범위만 재토큰화).
- **VaultKit:** 임시 디렉토리 픽스처(실제 Obsidian 샘플 vault) → 열거·색인 빌드·쿼리 결과·백링크 정확도·FTS 검색·FS워치·원자적 쓰기/백업.
- **EditorEngine:** **데코레이션 로직(순수 함수)**을 NSTextView와 분리해 단위 테스트(토큰+선택→DecorationSet). 렌더 블록은 스냅샷.
- **ExtensionSDK/AppCore:** 가짜 호스트 + 테스트 플러그인으로 생명주기·커맨드 등록·능력 범위 검증. 퍼스트파티 각 플러그인 자체 테스트.
- **App:** 로직 최소. 핵심 상호작용 스모크/UI 테스트는 후순위.

원칙: 개인+오픈소스 도구이므로 **순수 로직(토크나이저·데코 결정·쿼리·색인)에 테스트 무게**, UI는 가볍게.

---

## 9. 빌드 / 툴링

- **SPM 우선:** `Package.swift` 멀티 타깃(라이브러리들 + executable 앱). CI·오픈소스 친화(`.xcodeproj` 없음).
- **풀 Xcode 없이?** 이 머신엔 CLT만 → `swift build`로 SwiftUI GUI 실행 가능 여부를 **M0에서 검증**. 폴백: `swift-bundler` 또는 Makefile로 `.app` 조립, 혹은 Xcode 설치. (디버깅·Instruments·서명/공증은 Xcode가 편하므로 권장하되 필수 아님.)
- **`.app` 번들:** Info.plist + 번들 레이아웃을 빌드 스크립트로 산출.
- **의존성:** GRDB(SQLite) · swift-markdown(전체 문서) · ChimeHQ Neon(TextKit 2 스타일 적용; 채택 여부 M1 확정) · (후순위) SwiftTreeSitter. 마크다운 구조 파싱은 자체 토크나이저.

---

## 10. MVP 범위 & 마일스톤

**가장 위험한 통합점을 먼저 제거하는 walking-skeleton 순서.** 첫 구현 계획은 **M0**.

- **M0 — 골격:** SPM 워크스페이스 + 모듈 스켈레톤. 보관함 열기 + 파일트리 + (Live Preview 없는) 일반 NSTextView로 열기/저장. MetadataIndex 기본 빌드. ExtensionSDK 프로토콜 정의 + **"단어 수 세기" 사이드바 플러그인 1개**로 호스트↔플러그인 루프 검증. **실행되는 `.app` 산출**(SPM 빌드 경로 확정). → TextKit 브리지·SPM 앱 빌드·플러그인 루프 리스크 조기 제거.
- **M1 — 마커 숨김 스파이크 + Live Preview 기초:** 숨김 메커니즘 확정 + Neon 채택 여부 결정 후 heading·bold/italic·inline code.
- **M2 — Live Preview 확장:** link/wikilink, list/task, quote/callout, code block(첨부), image, frontmatter.
- **M3 — 색인 심화:** MetadataIndex 증분 + Dataview-lite + 백링크 패널 + **글로벌 검색(FTS, v1 확정)**.
- **M4 — 퍼스트파티 1차:** PeriodicNotes(기본 ON) + Templater(코어 토큰) + Calendar 패널.
- **M5 — 렌더:** mermaid 등 CoreRenderers + 코드블록 내부 하이라이트(tree-sitter, 선택).

---

## 11. 리스크

- **R1 마커 숨김(TextKit 2) — 최상 리스크.** zero-advancement 속성 vs 커스텀 레이아웃 프래그먼트. **M1 1순위 스파이크.** 풀리면 나머지는 요소 추가 반복. *(참고: on-keypress 스타일 적용의 깜빡임 문제는 ChimeHQ Neon 선례로 완화됨 — 남는 난점은 마커 hide/reveal 자체.)*
- **R2 SPM만으로 SwiftUI GUI `.app` 빌드.** M0에서 검증. 폴백: swift-bundler/Makefile 또는 Xcode 설치.
- **R3 Dataview 전체 재현 비용.** v1 lite로 한정(§13).
- **R4 향후 동적 로딩의 Swift ABI 불안정.** v1 compile-time이라 회피; 동적 로딩은 별도 설계.
- **R5 외부 편집 충돌.** 충돌 인지 리로드로 대응.

---

## 12. 로드맵 (post-v1)

그래프 뷰 · 캔버스 · **동적 플러그인 설치(무빌드)/XPC 격리** · 클라우드 동기화 · iOS/모바일 · 테마(CSS 동등) 시스템 · 전체 Dataview/인라인 DQL · **Importer(외부 포맷 가져오기)** · 퍼블리싱(블로그/정적사이트) 파이프라인 · AI/LLM 연동.

---

## 13. 범위 밖 (YAGNI)

- **Obsidian JS 플러그인/테마 생태계 실행** (네이티브 재구현으로 대체).
- 그래프 뷰, 캔버스.
- 동적 플러그인 설치/마켓플레이스(컴파일타임만).
- **Importer 구현**(SDK ⑤ 표면만 정의, 구현은 로드맵 — 이미 Obsidian 사용 중).
- 모바일/iOS, 클라우드 동기화, 실시간 협업.
- 테마/CSS 시스템(v1은 기본 라이트/다크만).
- 전체 Dataview JS 패리티, 인라인 DQL.
- 퍼블리싱/AI 연동(로드맵).

---

## 14. 미해결 / 구현 시 결정

**이번 검토에서 확정:**
- ✅ **이름: hanji.**
- ✅ **파서 경계:** 에디터=자체 증분 토크나이저, 전체 문서=swift-markdown, 스타일 적용=Neon(참조/채택), 코드블록 내부=tree-sitter(후순위). (§5.1)
- ✅ **글로벌 검색(FTS): v1 포함**(M3).
- ✅ **Importer: 우선순위 ↓, v1 제외**(로드맵). SDK ⑤ 표면만 정의.

**남은 결정:**
- **Neon 채택 vs 자체 스타일 적용 구현:** M1 스파이크에서 확정(외부 의존성 추가 여부).
- **문서/UI 언어:** 한국어 우선(현재) + 기여자용 영문 README/번역 시점.
- **풀 Xcode 설치 여부**(M0 결과에 따라).
- **git 레포 생성:** `hanji` 신규 레포 init(MIT) 시점.

---

## 부록: 조사 출처 (파서 경계)

- swift-markdown — cmark-gfm 기반, immutable/COW 트리(트리 편집은 효율적이나 파싱은 전체 문서): <https://github.com/swiftlang/swift-markdown>
- SwiftTreeSitter (ChimeHQ) — tree-sitter 증분 파싱 Swift 바인딩 + 중첩 언어 레이어: <https://github.com/ChimeHQ/SwiftTreeSitter>
- tree-sitter-markdown — 에디터 하이라이트용 마크다운 그래머(neovim/helix): <https://github.com/tree-sitter-grammars/tree-sitter-markdown>
- ChimeHQ Neon — 콘텐츠 기반 텍스트 스타일링, TextKit 1/2 인터페이스, 깜빡임 없는 on-keypress 하이라이트: <https://github.com/ChimeHQ/Neon>
