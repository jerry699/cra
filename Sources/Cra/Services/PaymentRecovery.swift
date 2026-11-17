import CraCEF
import AppKit

/// 支付通道修复（fork): a pay jump the trade backend rejects lands the tab on
/// error.taobao.com / err.taobao.com — the taobao trade system's failure dump. The usual
/// cause is a sign-in data conflict: aliyun's unified login seeds taobao-passport cookies
/// on aliyun.com, the cashier routes orders carrying them through the taobao trade flow,
/// and any break inside that flow (a blocked device-fingerprint script, a stale session)
/// ends here. Clearing the whole alibaba family's site data resets the routing; one
/// aliyun sign-in brings the session back; the pay jump then reaches alipay's QR cashier.
/// Full forensics: docs/model-training-observations.md (OBS-5).
@MainActor
enum PaymentRecovery {
    /// Offered once per launch: a deliberate visit to the error page must not nag on every load.
    private static var offeredThisLaunch = false

    private static func isTradeFailureLanding(_ url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host else { return false }
        return host == "error.taobao.com" || host == "err.taobao.com"
    }

    /// The origins whose data the repair clears: every alibaba-family site the pay flow touches.
    private static let origins = [
        "https://aliyun.com", "https://www.aliyun.com", "https://cashier.aliyun.com",
        "https://finance.aliyun.com", "https://account.aliyun.com", "https://wanwang.aliyun.com",
        "https://taobao.com", "https://www.taobao.com", "https://login.taobao.com",
        "https://h5api.m.taobao.com", "https://www.alipay.com", "https://my.alipay.com",
        "https://mclient.alipay.com",
    ]

    static func offerRepairIfTradeFailure(url: String, browser: CraBrowser) {
        guard !offeredThisLaunch, isTradeFailureLanding(url), url.hasPrefix("http") else { return }
        offeredThisLaunch = true
        CraLog.note("PaymentRecovery: a trade-failure landing — offering the site-data repair")
        let dialog = AppDialog(title: L10n.tr("Payment channel error"),
                               message: L10n.tr("The pay jump was rejected. This is usually a sign-in data conflict: clearing the alibaba sites' data and signing in to aliyun once more restores it."),
                               actions: [DialogAction(L10n.tr("Clear alibaba site data")),
                                         DialogAction(L10n.tr("Not now"), role: .cancel)])
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            repair(using: browser)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            dialog.present(over: window, completion: answer)
        } else {
            answer(dialog.runModal(over: nil))
        }
    }

    /// Clears the family's site data through the tab's own DevTools session (profile-wide for
    /// each origin), then brings the tab to aliyun's home for the sign-in.
    private static func repair(using browser: CraBrowser) {
        CraLog.note("PaymentRecovery: clearing \(origins.count) alibaba origins")
        var pending = origins.count
        let done: (String?, String?) -> Void = { _, error in
            if let error { NSLog("Cra: PaymentRecovery clear failed: %@", error) }
            pending -= 1
            if pending == 0 {
                DispatchQueue.main.async {
                    browser.loadURL("https://www.aliyun.com/")
                }
            }
        }
        for origin in origins {
            let params = ["origin": origin,
                          "storageTypes": "cookies,local_storage,session_storage,indexeddb,cache_storage"]
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8), as: UTF8.self)
            browser.sendDevToolsMethod("Storage.clearDataForOrigin", params: json, completion: done)
        }
    }
}
