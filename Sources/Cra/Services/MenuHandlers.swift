import AppKit
import CraCEF

/// 中国版右键菜单行为的中枢（P5 解耦 #5）。上游 MainWindowController 不含这里的
/// 任何逻辑——delegate 收到菜单事件后把参数转给这里，上游文件里的接触面只有
/// 两个一行的转发调用。
///
/// 翻译（W1）：选中文本 → 本地 1.7B → Arc 查找式气泡（黄高亮 + 尾巴）。
/// 蒸馏（W2-C）：页面音视频 → 本地转写/润色/摘要 → 用户笔记目录的 Markdown。
@MainActor
enum MenuHandlers {
    /// W1 选中文本翻译的完整流程（从 browserManagerTranslateSelection 调来）。
    /// `token` 交给 TranslationHUD 供 superseded-selection 保护。
    static func translateSelection(text: String, at screenPoint: NSPoint, in window: NSWindow,
                                   page: CraBrowser, token: Int) {
        let instructions = TidyTranslate.instructions(for: text)
        let original = text
        Task { @MainActor in
            let answer = await LocalInference.shared.ask(
                system: instructions, user: TidyTranslate.prompt(original),
                grammar: nil, maxTokens: 256, context: 2048,
                timeout: 60, threads: 4,
                helper: MaxLocal.helperURL ?? URL(fileURLWithPath: "/usr/bin/false"),
                model: MaxLocal.modelURL ?? URL(fileURLWithPath: "/dev/null"))
            guard let translation = TidyTranslate.clean(answer ?? "", original: original) else {
                TranslationHUD.fail(token: token)
                return
            }
            TranslationHUD.finish(translation, token: token)
        }
    }

    /// W2-C 页面媒体蒸馏的完整流程（从 browserManagerDistillPageMedia 调来）。
    static func distillPageMedia(browser: CraBrowser, pageURL: String, pageTitle: String) {
        DistillStatusHUD.show("准备中")
        Task { @MainActor in
            let outcome = await MediaDistillService.distill(browser: browser, pageURL: pageURL,
                                                            pageTitle: pageTitle,
                                                            progress: { DistillStatusHUD.phase($0) })
            switch outcome {
            case .saved(let url):
                DistillStatusHUD.finish(url.lastPathComponent)
            case .noMedia:
                DistillStatusHUD.finish(L10n.tr("No audio or video found on this page"), failed: true)
            case .pageStillLoading:
                DistillStatusHUD.finish(L10n.tr("The video is still loading — try again in a moment"), failed: true)
            case .noSpeech:
                DistillStatusHUD.finish(L10n.tr("This video has no speech to distill (music or silence)"), failed: true)
            case .fetchFailed:
                DistillStatusHUD.finish(L10n.tr("Could not fetch the page's media"), failed: true)
            case .decodeFailed:
                DistillStatusHUD.finish(L10n.tr("Could not transcribe the media's audio"), failed: true)
            case .noModel:
                DistillStatusHUD.finish(L10n.tr("The transcription model is not downloaded yet"), failed: true)
            case .noAnswer:
                DistillStatusHUD.finish(L10n.tr("Translation failed — the local model had no answer"), failed: true)
            }
        }
    }
}
