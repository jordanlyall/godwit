import SwiftUI
import WebKit

/// Shows a message's sanitized HTML (GetMessage) with JavaScript off and no
/// network loads; links open in Safari. Reports its content height so the
/// thread can scroll as one page.
struct MessageBodyView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.dataDetectorTypes = [.link, .phoneNumber]
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        context.coordinator.observe(web)
        // Belt and braces with the sanitizer: block every remote load.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "godwit-no-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) { list, _ in
            if let list { web.configuration.userContentController.add(list) }
            web.loadHTMLString(Self.page(html), baseURL: nil)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
        html,body{margin:0;padding:0;font:-apple-system-body;word-wrap:break-word;overflow-wrap:anywhere}
        img{max-width:100%!important;height:auto!important}
        table{width:100%!important;max-width:100%!important;table-layout:auto}
        td,th{max-width:100vw;word-break:break-word}
        pre{white-space:pre-wrap}
        </style></head><body>\(body)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var height: CGFloat
        private var token: NSKeyValueObservation?
        init(height: Binding<CGFloat>) { _height = height }

        func observe(_ web: WKWebView) {
            token = web.scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                let h = sv.contentSize.height
                DispatchQueue.main.async { if let self, h > 0, abs(self.height - h) > 1 { self.height = h } }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
