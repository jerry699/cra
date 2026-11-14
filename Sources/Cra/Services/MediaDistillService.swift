import Foundation
import AVFoundation
import CraCEF

/// W2-C: distill the page's audio/video into a local note. The page's own media URL is
/// found by injected JS — bilibili's `window.__playinfo__.dash.audio` (the signed audio
/// stream the player itself requests) or, elsewhere, a plain <video>/<audio> src — then
/// fetched with the page's cookies, transcribed by CraWhisper and summarized by the local
/// 1.7B. The note lands in the user's notes directory. Only what the user asked for is
/// distilled, and nothing leaves the Mac.
/// MainActor end to end: every CEF call here (the DevTools pipe write, CefURLRequest) must
/// run on the UI thread — an unisolated async hop crashes CefURLRequest::Create. The
/// blocking transcription already leaves via Task.detached.
@MainActor
enum MediaDistillService {
    /// The user's notes directory (their test vault; a Settings override comes later).
    static var notesDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: "notesDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("日常记录")
    }

    /// The page's media, as the injected script reports it. `k` marks the kind: "bili" is
    /// bilibili's audio DASH stream (an fMP4 AAC — AVFoundation reads it), "el" a plain
    /// element src.
    struct Medium { let url: String; let kind: String }

    /// Runs in the page's MAIN world (see evaluateInPage). The player-embedded playinfo
    /// CANNOT be trusted on B站: SPA navigations (the autoplay chain) swap the URL and
    /// title while the static `script#__playinfo__` in the HTML keeps the FIRST video the
    /// page ever loaded, and even `location.pathname` inside the document can lag Cra's
    /// tab URL (pushState commits late — one run then distilled a song video's audio under
    /// the next video's title). The BV id is therefore INJECTED by Swift from the tab's
    /// address bar — the one source the user controls — and the audio is fetched from
    /// bilibili's own API for that id: same-origin fetch, cookies and Referer ride along.
    /// The live playinfo (aid-validated) and plain element srcs stay as fallbacks.
    private static func discoverScript(bv: String?) -> String {
        let literal = bv.map { "\"" + $0 + "\"" } ?? "null"
        return """
        (async function(){
          var bv=__BVID__;
          if(!bv){ try{ bv=(location.pathname.match(/\\/(?:video\\/)?(BV[0-9A-Za-z]{10})/)||[])[1]||null; }catch(e){} }
          async function apiAudio(bv){
            try{
              var v=await (await fetch('https://api.bilibili.com/x/web-interface/view?bvid='+bv,{credentials:'include'})).json();
              if(!v||!v.data) return [];
              var r=await (await fetch('https://api.bilibili.com/x/player/playurl?bvid='+bv+'&cid='+v.data.cid+'&aid='+v.data.aid+'&fnval=16',{credentials:'include'})).json();
              var d=r&&r.data&&r.data.dash;
              if(d&&d.audio&&d.audio.length){
                // A logged-in playurl lists hi-res tracks first — FLAC (30251) and Dolby
                // (30250) decode to silence in AVFoundation and whisper hears "(音樂)".
                // Only the AAC m4s tracks (30216/30232/30280) decode to real speech.
                var aac=d.audio.filter(function(a){return a.id===30216||a.id===30232||a.id===30280;});
                var pick=aac.length?aac:d.audio;
                return pick.map(function(a){return {u:a.baseUrl,k:'bili'};});
              }
            }catch(e){}
            return [];
          }
          function liveList(){
            var out=[];
            try{
              var p=window.__playinfo__;
              var d=p&&p.data&&p.data.dash?p.data.dash:(p&&p.dash?p.dash:null);
              if(d&&d.audio&&d.audio.length){
                var aac=d.audio.filter(function(a){return a.id===30216||a.id===30232||a.id===30280;});
                out=out.concat((aac.length?aac:d.audio).map(function(a){return {u:a.baseUrl,k:'bili'};}));
              }
            }catch(e){}
            return out;
          }
          // The live playinfo is only used when it provably belongs to this page (aid check).
          function liveMatchesPage(bv){
            try{
              var A='FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZfRaEbby';
              if(!/^BV[0-9A-Za-z]{10}$/.test(bv)) return false;
              var c=bv.split('');
              var t=c[3];c[3]=c[9];c[9]=t;
              var t2=c[4];c[4]=c[7];c[7]=t2;
              var n=0n;
              for(var i=3;i<c.length;i++) n=n*58n+BigInt(A.indexOf(c[i]));
              var expect=Number((n & 2251799813685247n) ^ 23442827791579n);
              var p=window.__playinfo__;
              var aid=p?(p.data&&p.data.aid)||p.aid||null:null;
              return aid!==null&&aid===expect;
            }catch(e){ return false; }
          }
          var out=[];
          if(bv) out=await apiAudio(bv);           // always current: asked for by bvid
          if(!out.length&&liveMatchesPage(bv||'')) out=liveList();
          if(!out.length){                          // non-bilibili pages: plain element srcs
            try{
              var els=document.querySelectorAll('video,audio');
              for(var j=0;j<els.length;j++){var src=els[j].src||els[j].currentSrc;
                if(src&&src.indexOf('blob:')!==0&&src.indexOf('http')===0) out.push({u:src,k:'el'});}
            }catch(e){}
          }
          return JSON.stringify({stale:false,media:out.slice(0,8)});
        })()
        """
            .replacingOccurrences(of: "__BVID__", with: literal)
    }

    /// What became of a distillation, for the caller's toast.
    enum Outcome {
        case saved(URL)
        case noMedia
        /// The player's playinfo never matched the page's video (SPA navigation lag): the
        /// audio would be the PREVIOUS video's — refuse rather than distill the wrong one.
        case pageStillLoading
        /// A music-only or silent video: whisper hears "(音樂)" for seven minutes. An
        /// honest refusal beats a note of ninety identical lines (user report).
        case noSpeech
        case fetchFailed
        case decodeFailed
        case noModel
        case noAnswer
    }

    /// One browser-level CDP call over the remote-debugging pipe (fd 3/4 — the trusted
    /// client extensions use). The per-browser SendDevToolsMessage path answers
    /// "SendDevToolsMessage failed" on this setup (no agent attaches for a bare
    /// CefDevToolsMessageObserver), so the pipe is the way in.
    private static func browserCDP(_ method: String, _ params: String, session: String?) async -> String? {
        CraLog.note("Distill: CDP \(method) →")
        let result: String? = await withCheckedContinuation { cont in
            CraCEFRuntime.sendBrowserDevToolsMethod(method, params: params, sessionID: session) { result, error in
                CraLog.note("Distill: CDP \(method) ← \(error != nil ? "error \(error!)" : result.map { "reply \(String($0.prefix(150)))" } ?? "nil reply, nil error")")
                cont.resume(returning: result)
            }
        }
        return result
    }

    /// Runtime.evaluate in the PAGE's main world: page globals (`window.__playinfo__`)
    /// are visible there, which the isolated world cannot see. The page is found among the
    /// browser's targets by URL, attached with flatten, and evaluated over that session.
    private static func evaluateInPage(pageURL: String, expression: String) async -> String? {
        let targets = await browserCDP("Target.getTargets", "{}", session: nil)
        guard let targets,
              let parsed = try? JSONSerialization.jsonObject(with: Data(targets.utf8)) as? [String: Any],
              let infos = parsed["targetInfos"] as? [[String: Any]] else { return nil }
        let url = URL(string: pageURL)
        // The entry and the target may disagree on query, fragment and the trailing slash;
        // the host plus the slash-normalized path decide.
        let wantedPath = (url?.path ?? "").hasSuffix("/") ? String(url!.path.dropLast()) : (url?.path ?? "")
        let targetID = infos.compactMap { info -> String? in
            guard info["type"] as? String == "page", let infoURL = info["url"] as? String,
                  let infoHost = URL(string: infoURL)?.host else { return nil }
            guard infoHost == url?.host else { return nil }
            var infoPath = URL(string: infoURL)?.path ?? ""
            if infoPath.hasSuffix("/") { infoPath = String(infoPath.dropLast()) }
            return infoPath == wantedPath ? (info["targetId"] as? String) : nil
        }.first
        guard let targetID else {
            CraLog.note("Distill: no page target for \(pageURL)")
            return nil
        }
        let attach = await browserCDP("Target.attachToTarget",
                                      "{\"targetId\":\"\(targetID)\",\"flatten\":true}", session: nil)
        // The pipe hands back the RESULT payload already stripped of its {"id":…,"result":…}
        // envelope: the attach reply is {"sessionId":"…"} as-is.
        guard let attach,
              let attachParsed = try? JSONSerialization.jsonObject(with: Data(attach.utf8)) as? [String: Any],
              let session = attachParsed["sessionId"] as? String else {
            CraLog.note("Distill: attach reply without sessionId \(attach.map { String($0.prefix(150)) } ?? "nil")")
            return nil
        }
        let params: String
        if let data = try? JSONSerialization.data(withJSONObject: ["expression": expression, "returnByValue": true, "awaitPromise": true]),
           let string = String(data: data, encoding: .utf8) {
            params = string
        } else {
            CraLog.note("Distill: cannot serialize the evaluate params")
            return nil
        }
        let raw = await browserCDP("Runtime.evaluate", params, session: session)
        // The evaluate reply, envelope-stripped: {"result":{"type":"…","value":"…"}} — the
        // inner "result" is the RemoteObject, not another envelope.
        guard let raw,
              let outer = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let inner = outer["result"] as? [String: Any],
              let value = inner["value"] as? String else {
            CraLog.note("Distill: evaluate shape unexpected \(raw.map { String($0.prefix(200)) } ?? "nil")")
            return nil
        }
        return value
    }

    /// The page's media, or nil (also nil on any evaluation trouble — the toast is the same).
    /// `nil` media with `stale` true means the page's player never caught up with its own
    /// URL — distilling then would serve the previous video (the user's bug report).
    private static func discover(pageURL: String) async -> (media: [Medium], stale: Bool) {
        CraLog.note("Distill: discovering for \(pageURL)")
        // The BV id comes from Cra's tab URL — the address bar is the user's own statement
        // of what they are distilling. The page document can lag it (pushState commits late).
        let bv = pageURL.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression)
            .map { String(pageURL[$0]) }
        if let bv { CraLog.note("Distill: page BV \(bv)") }
        guard let json = await evaluateInPage(pageURL: pageURL, expression: discoverScript(bv: bv)) else {
            CraLog.note("Distill: discovery script returned nothing")
            return ([], false)
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let list = parsed["media"] as? [[String: String]] ?? []
        let stale = parsed["stale"] as? Bool ?? false
        let media: [Medium] = list.compactMap { item -> Medium? in
            guard let url = item["u"], url.hasPrefix("http") else { return nil }
            return Medium(url: url, kind: item["k"] ?? "el")
        }
        CraLog.note("Distill: found \(media.count) media source(s), stale=\(stale)")
        return (media, stale)
    }

    /// Plain URLSession, no proxy (the MaxRemote lesson: domestic CDNs break through the
    /// system proxy's overseas exit).
    private static func directFetch(_ url: String, headers: [String: String]) async -> Data? {
        guard let requestURL = URL(string: url) else { return nil }
        var request = URLRequest(url: requestURL)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            CraLog.note("Distill: direct fetch status \(status), \(data.count) bytes")
            // A 200 with a short body is a truncated download: it decodes to seconds of BGM
            // and a transcript of "(音樂)". Refuse it — the caller re-fetches.
            let expected = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
            if expected > 0, data.count < expected {
                CraLog.note("Distill: direct fetch truncated (\(data.count) of \(expected) bytes)")
                return nil
            }
            return (status == 200 || status == 206) ? data : nil
        } catch {
            CraLog.note("Distill: direct fetch failed (\(error.localizedDescription))")
            return nil
        }
    }

    /// CefURLRequest with the page's stored cookies — the fallback for CDNs that want them.
    private static func cefFetch(_ url: String, headers: [String: String]) async -> Data? {
        let data: Data? = await withCheckedContinuation { cont in
            CraCEFRuntime.fetchBinaryURL(url, headers: headers, profilePath: nil) { status, finalURL, body in
                CraLog.note("Distill: cef fetch status \(status), \(body.count) bytes, final \(finalURL.prefix(120))")
                cont.resume(returning: (status == 200 || status == 206) ? body : nil)
            }
        }
        return data
    }

    /// The whole pipeline. Blocking on the network and the model; call from a Task. `progress`
    /// feeds the status card — a silent minute-long run read as "nothing happened" (user report).
    static func distill(browser: CraBrowser, pageURL: String, pageTitle: String,
                        progress: @MainActor (String) -> Void = { _ in }) async -> Outcome {
        CraLog.note("Distill: run for \(pageURL) (\(browser == nil ? "nil" : "browser ok"))")
        let (media, stale) = await discover(pageURL: pageURL)
        if media.isEmpty, stale { return .pageStillLoading }
        guard let medium = media.first else { return .noMedia }
        progress("拉取音轨")
        guard let modelURL = WhisperService.modelURL, WhisperService.isEnabled else { return .noModel }
        guard let helperURL = MaxLocal.helperURL else { return .noModel }

        // Bilibili's CDN and most others answer only to the page's own origin: the fetch
        // goes out with the page's Referer and a standard Chrome UA (cra sends none).
        var headers = ["Referer": pageURL,
                       "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"]
        if medium.kind == "bili" { headers["Referer"] = "https://www.bilibili.com/" }

        // First try a plain URLSession: media CDNs like bilivideo.com often redirect across
        // domains, and Chromium's stack re-evaluates headers (Referer!) per redirect while
        // URLSession keeps the originals. CefURLRequest stays as the cookie-backed fallback.
        // The whole fetch→decode→transcribe round runs twice: B站's CDNs (the P2P mcdn
        // mirrors especially) sometimes answer 200 with a TRUNCATED file, which decodes to
        // a few seconds of BGM and a transcript of "(音樂)" — a second fetch usually gets
        // the complete file.
        let ext = medium.kind == "el"
            ? ((URL(string: medium.url)?.pathExtension.lowercased()).flatMap { ["mp3", "m4a", "mp4", "mov", "m4b", "aac", "wav"].contains($0) ? $0 : nil } ?? "m4a")
            : "m4a"
        var duration = ""
        var rawTranscript: String?
        for attempt in 0..<2 {
            if attempt == 1 { progress("重新拉取音轨") }
            let direct = await Self.directFetch(medium.url, headers: headers)
            let audioData = direct != nil ? direct : await Self.cefFetch(medium.url, headers: headers)
            guard let audioData, !audioData.isEmpty else { continue }

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("cra-distill-\(UUID().uuidString).\(ext)")
            guard (try? audioData.write(to: file)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: file) }

            // The note's header wants the media's length; cheap to read while the file is here.
            let seconds = CMTimeGetSeconds(AVURLAsset(url: file).duration)
            duration = seconds.isFinite && seconds > 0
                ? String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) : ""

            // Whisper blocks (a minute or more on a long video): off the main thread.
            progress(attempt == 0 ? "转写中（最久的一步）" : "转写中（重试）")
            rawTranscript = await Task.detached(priority: .utility) {
                WhisperService.transcribe(mediaURL: file)
            }.value
            if rawTranscript != nil { break }
        }
        guard let rawTranscript, !rawTranscript.isEmpty else { return .decodeFailed }
        // Music-only or silent videos transcribe to "(音樂)"/"(Music)" lines. Strip the
        // timestamps and the parenthesized non-speech markers: under ~10 chars of real
        // speech there is nothing to distill — refuse instead of writing a junk note.
        let speech = rawTranscript.split(separator: "\n").reduce(0) { count, line in
            let text = line.split(separator: "]", maxSplits: 1).last.map { String($0) } ?? String(line)
            let t = text.trimmingCharacters(in: .whitespaces)
            let nonSpeech = t.isEmpty || (t.hasPrefix("(") && t.hasSuffix(")"))
            return count + (nonSpeech ? 0 : t.count)
        }
        guard speech >= 10 else {
            CraLog.note("Distill: no speech in the transcript (\(speech) chars)")
            return .noSpeech
        }
        progress("生成摘要")

        // Whisper prints one short segment per line: choppy one-liners nobody can read.
        // Merge them into paragraphs at sentence ends, each starting with its timestamp.
        let merged = Self.formatTranscript(rawTranscript)
        progress("润色文稿")
        let transcript = await Self.polish(merged, pageTitle: pageTitle, progress: progress)

        // W2-B: the local 1.7B distills the polished transcript in two passes — MAP: every
        // chunk of the WHOLE video yields its key points (a single pass over the first 2 500
        // chars lost the back half of long talks); REDUCE: the collected points merge into a
        // theme line and the most valuable takeaways. MaxLocal.ask carries the free-memory
        // gate (a bare LocalInference.ask once crashed the helper's load under pressure and
        // the status-1 reply was a silent nil).
        let extractInstructions = """
        You extract key points from part of a video transcript. Reply in Simplified Chinese \
        with short lines starting '- ', each line ONE concrete point actually said in this \
        part: a product/tool name, a number, a step, a recommendation. Skip greetings, \
        filler and channel promotion. No preamble, no headings.
        """
        var points: [String] = []
        let chunks = Self.chunks(transcript, size: 1100)
        for (index, chunk) in chunks.enumerated() {
            progress(chunks.count > 1 ? "提取要点 \(index + 1)/\(chunks.count)" : "提取要点")
            if let answer = await Self.askWithRetry(instructions: extractInstructions,
                                                    prompt: chunk, maxTokens: 512) {
                for line in answer.split(separator: "\n") {
                    var t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("-") || t.hasPrefix("•") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
                    if t.count > 4 { points.append(t) }
                }
            }
        }
        progress("生成总结")
        // Dedupe near-identical points (the same tool named in two chunks) before the reduce.
        var seen: [String] = []
        for point in points {
            if !seen.contains(where: { $0.prefix(12) == point.prefix(12) }) { seen.append(point) }
        }
        let reduceInstructions = """
        You distill a video from the key points extracted over its whole transcript. Reply \
        in Simplified Chinese: the FIRST line is one sentence stating what the video is \
        about; then up to 6 lines starting '- ', the most valuable takeaways for a reader — \
        merge overlapping points, keep specifics (names, numbers, steps). Nothing else.
        """
        let bulletText = seen.map { "- " + $0 }.joined(separator: "\n")
        var answer = await Self.askWithRetry(instructions: reduceInstructions,
                                             prompt: bulletText.isEmpty ? "（本段没有可提取的要点）" : bulletText,
                                             maxTokens: 512)
        CraLog.note("Distill: summary answer \(answer.map { "\(String($0.prefix(100)))…" } ?? "nil") from \(seen.count) points")
        // Not TidyTranslate.clean — that keeps one line for translations; the summary is
        // multi-line, so just trim wrapper quotes and drop empties.
        let trimmed = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'“”‘’")))
        let summary = trimmed.isEmpty ? nil : trimmed

        let note = renderNote(title: pageTitle, source: pageURL, duration: duration,
                              summary: summary, transcript: transcript)
        do {
            let url = try writeNote(note, pageTitle: pageTitle)
            return .saved(url)
        } catch {
            CraLog.note("Distill: cannot write the note (\(error))")
            return .fetchFailed
        }
    }

    /// Splits text into paragraph-aligned chunks of ~`size` chars, each well inside the
    /// model's context (map passes over the WHOLE video, not just its first 2 500 chars).
    private static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for paragraph in text.split(separator: "\n\n") {
            if current.count + paragraph.count > size, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// One model answer with a single retry: a declined request kills the helper, and a
    /// fresh process usually loads fine (the failures looked like memory pressure).
    private static func askWithRetry(instructions: String, prompt: String, maxTokens: Int) async -> String? {
        let answer = await MaxLocal.ask(instructions: instructions, prompt: prompt,
                                        grammar: nil, maxTokens: maxTokens, timeout: 180)
        if answer != nil { return answer }
        try? await Task.sleep(for: .seconds(2))
        return await MaxLocal.ask(instructions: instructions, prompt: prompt,
                                  grammar: nil, maxTokens: maxTokens, timeout: 180)
    }

    /// The 1.7B edits the whisper draft the way a human transcriber would: recognition
    /// errors fixed (以握容→摇粒绒, 霓龙→尼龙, 翅脉→尺码…), punctuation added, run-ons
    /// split, flow smoothed — meaning and the [mm:ss] stamps untouched. The draft feeds the
    /// model paragraph-chunk by paragraph-chunk (each well inside the 4096 context); a chunk
    /// whose pass fails keeps its draft text, so the note never loses content to the editor.
    private static func polish(_ transcript: String, pageTitle: String,
                               progress: @MainActor (String) -> Void) async -> String {
        let instructions = """
        You are editing a Chinese speech-to-text draft. Fix recognition errors: wrong \
        homophones like 以握容→摇粒绒, 霓龙→尼龙, 翅脉→尺码, 丑单→出手; clothing and \
        product words to watch for: 摇粒绒、尼龙、尺码、棉服、冲锋衣、羽绒服、内搭、收纳袋、 \
        压胶. The media's title, which spells brand and product names correctly, is: \
        "\(pageTitle)". Add natural punctuation, split run-on sentences, and smooth the flow \
        — as a human editor would. Keep the meaning exactly, keep every [mm:ss] timestamp at \
        its paragraph start, and reply in Simplified Chinese with only the corrected text.
        """
        let chunks = Self.chunks(transcript, size: 1100)
        var polished: [String] = []
        for (index, chunk) in chunks.enumerated() {
            progress("润色文稿 \(index + 1)/\(chunks.count)")
            if let answer = await MaxLocal.ask(instructions: instructions, prompt: chunk,
                                               grammar: nil, maxTokens: 1024, timeout: 180) {
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                polished.append(trimmed.isEmpty ? chunk : trimmed)
            } else {
                polished.append(chunk)
            }
        }
        return polished.joined(separator: "\n\n")
    }

    /// Whisper prints one short segment per line ("[00:03] 但介面一眼假") — choppy
    /// one-liners nobody can read. Merge them into paragraphs at sentence ends (。！？),
    /// each paragraph starting with the timestamp of its first segment; a run that never
    /// sentences out is still cut at ~120 chars so no paragraph swallows the transcript.
    static func formatTranscript(_ raw: String) -> String {
        var paragraphs: [String] = []
        var buffer = ""
        var bufferTime = ""
        for line in raw.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { continue }
            let time = String(s[s.index(after: s.startIndex)..<close])
            let text = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if buffer.isEmpty { bufferTime = time }
            buffer += text
            if text.hasSuffix("。") || text.hasSuffix("！") || text.hasSuffix("？") || buffer.count > 120 {
                paragraphs.append("[\(bufferTime)] \(buffer)")
                buffer = ""
            }
        }
        if !buffer.isEmpty { paragraphs.append("[\(bufferTime)] \(buffer)") }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The note: frontmatter for the vault's graph, the summary first, the full transcript
    /// behind a separator for searching and citing.
    /// The note: frontmatter, then the DISTILLATE — theme line + key points (the user: the
    /// summary is the essence, the transcript is the source material) — and the full edited
    /// transcript as an appendix. Paragraph timestamps stay in the appendix only: they cost
    /// nothing to read past and let a reader jump back to the video moment.
    private static func renderNote(title: String, source: String, duration: String,
                                   summary: String?, transcript: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var body = """
        ---
        title: \(title)
        source: \(source)
        distilled: \(formatter.string(from: Date()))
        \(duration.isEmpty ? "" : "duration: \(duration)")
        ---
        """
        if let summary, !summary.isEmpty {
            // The model's first line is the theme; the rest are the key-point bullets.
            let lines = summary.split(separator: "\n").map(String.init)
            let theme = lines.first.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-• ")) } ?? ""
            let points = lines.dropFirst().joined(separator: "\n")
            if !theme.isEmpty { body += "\n## 主题\n\n\(theme)\n" }
            if !points.isEmpty { body += "\n## 要点\n\n\(points)\n" }
        }
        body += "\n## 转写（附录）\n\n\(transcript)\n"
        return body
    }

    /// <safe title>.md in the notes directory (created on demand); a clash gets (2), (3)…
    private static func writeNote(_ note: String, pageTitle: String) throws -> URL {
        let dir = notesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let base = pageTitle.components(separatedBy: invalid)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "蒸馏笔记" : String(base.prefix(60))
        var url = dir.appendingPathComponent("\(stem).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem) (\(n)).md")
            n += 1
        }
        try note.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
