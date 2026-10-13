import SwiftUI
import WebKit
import Darwin
import cmark_gfm
import cmark_gfm_extensions

private enum MarkdownHTML {
    static func render(_ source: String) throws -> String {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { throw failure() }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            guard let syntax = cmark_find_syntax_extension(name) else { throw failure() }
            cmark_parser_attach_syntax_extension(parser, syntax)
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { throw failure() }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, CMARK_OPT_SOURCEPOS, cmark_parser_get_syntax_extensions(parser)) else {
            throw failure()
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    private static func failure() -> NSError {
        NSError(domain: "HeyNote", code: 4, userInfo: [NSLocalizedDescriptionKey: "Markdown could not be rendered. Switch to Edit to access the source."])
    }

    static func page(_ body: String, token: String, fontSize: CGFloat) -> String {
        #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; script-src 'nonce-\#(token)'; base-uri 'none'; form-action 'none'">
        <style>
        :root{color-scheme:light dark;--text:#17171a;--muted:#6a6a70;--bg:#fff;--field:#e4e4e9;--line:#dedee3;--accent:#01707a}
        @media(prefers-color-scheme:dark){:root{--text:#f4f4f6;--muted:#a1a1a8;--bg:#1c1c1e;--field:#252528;--line:#38383a;--accent:#3fd3a6}}
        *{box-sizing:border-box}html{background:var(--bg);color:var(--text);-webkit-text-size-adjust:100%}
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:\#(fontSize)px;line-height:1.5;margin:0;padding:16px 18px;overflow-wrap:anywhere}
        p,ul,ol,blockquote,pre,table{margin:0 0 16px}h1,h2,h3,h4,h5,h6{font-weight:600;line-height:1.25;margin:24px 0 16px}body>:first-child{margin-top:0}
        h1{font-size:2em}h2{font-size:1.5em}h3{font-size:1.25em}h4,h5,h6{font-size:1em}h1,h2{padding-bottom:.3em;border-bottom:1px solid var(--line)}
        a{color:var(--accent)}strong{font-weight:600}img{max-width:100%;height:auto}blockquote{border-left:4px solid var(--line);padding-left:16px;color:var(--muted)}
        code,pre{font-family:ui-monospace,"SFMono-Regular",Menlo,monospace;font-size:.95em}code{background:var(--field);padding:2px 4px;border-radius:4px}pre{background:var(--field);padding:14px;border-radius:8px;overflow:auto;overflow-wrap:normal}pre code{background:none;padding:0;font-size:inherit}
        ul,ol{padding-left:28px}li{margin:.25em 0}li>p:last-child{margin-bottom:0}li.task{list-style:none;position:relative}input[type=checkbox]{accent-color:var(--accent);width:22px;height:22px;vertical-align:middle;margin:0 7px 3px -27px;cursor:pointer}
        table{border-collapse:collapse;display:block;overflow-x:auto;white-space:normal}td,th{border:1px solid var(--line);padding:6px 13px}tr:nth-child(even){background:var(--field)}hr{border:0;border-top:1px solid var(--line);margin:24px 0}
        </style></head><body>\#(body)
        <script nonce="\#(token)">
        (()=>{
          const token="\#(token)";
          const blocks=[...document.querySelectorAll('[data-sourcepos]')].map(e=>{const p=e.dataset.sourcepos.match(/^(\d+):\d+-(\d+):\d+$/);return p?{e,start:Number(p[1]),end:Number(p[2])}:null}).filter(Boolean);
          function captureLine(){let selected=null;for(const b of blocks){const r=b.e.getBoundingClientRect();if(r.bottom>18&&r.top<=18&&(!selected||b.end-b.start<selected.end-selected.start))selected=b;}if(!selected){selected=blocks.find(b=>b.e.getBoundingClientRect().bottom>18)||blocks[blocks.length-1];}if(!selected)return 1;const r=selected.e.getBoundingClientRect();return selected.start+Math.min(.999,Math.max(0,(18-r.top)/Math.max(1,r.height)))*(selected.end-selected.start+1);}
          function restoreLine(line){const matches=blocks.filter(b=>b.start<=line&&b.end+1>line).sort((a,b)=>(a.end-a.start)-(b.end-b.start));const b=matches[0]||blocks.find(b=>b.start>=line)||blocks[blocks.length-1];if(!b)return;const r=b.e.getBoundingClientRect();const fraction=Math.min(1,Math.max(0,(line-b.start)/Math.max(1,b.end-b.start+1)));window.scrollTo(0,window.scrollY+r.top+fraction*r.height-18);}
          function edge(bottom){window.scrollTo(0,bottom?document.documentElement.scrollHeight:0);}
          function enable(value){document.querySelectorAll('input[type=checkbox]').forEach(input=>{input.disabled=!value;});}
          document.querySelectorAll('input[type=checkbox]').forEach(input=>{const li=input.closest('li[data-sourcepos]');if(!li)return;li.classList.add('task');input.disabled=false;input.setAttribute('aria-label',li.textContent.trim());input.addEventListener('change',()=>window.webkit.messageHandlers.note.postMessage({action:'task',token,line:Number(li.dataset.sourcepos.split(':')[0]),checked:input.checked}));});
          window.note={captureLine,restoreLine,edge,enable};
        })();
        </script></body></html>
        """#
    }
}

final class BlockWebView: WKWebView {
    var supplementalMenu: (() -> [UIMenuElement])?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let actions = supplementalMenu?(), !actions.isEmpty else { return }
        let menu = UIMenu(title: "Block actions", children: actions)
        if builder.menu(for: .standardEdit) != nil { builder.insertSibling(menu, afterMenu: .standardEdit) }
        else { builder.insertChild(menu, atEndOfMenu: .root) }
    }
}

struct MarkdownBlockReader: UIViewRepresentable {
    @Binding var text: String
    let blockID: UUID
    let scrollRequest: EditorScrollRequest?
    let controls: EditorControls
    let active: Bool
    var supplementalMenu: (() -> [UIMenuElement])? = nil
    let error: (String) -> Void
    @Environment(\.sizeCategory) private var sizeCategory

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> BlockWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "note")
        let view = BlockWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = AppDesign.raisedUI
        view.scrollView.backgroundColor = AppDesign.raisedUI
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = view
        controls.reader = context.coordinator
        return view
    }

    func updateUIView(_ view: BlockWebView, context: Context) {
        context.coordinator.parent = self
        controls.reader = context.coordinator
        view.supplementalMenu = supplementalMenu
        context.coordinator.enabled = context.environment.isEnabled
        context.coordinator.update()
    }

    static func dismantleUIView(_ view: BlockWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "note")
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, MarkdownReading {
        var parent: MarkdownBlockReader
        weak var webView: BlockWebView?
        var enabled = true
        private var loadedID: UUID?
        private var source = ""
        private var ready = false
        private var token = ""
        private var pendingLine: Double?
        private var pendingRequest: EditorScrollRequest?
        private var requestID: UUID?
        private var fontSize: CGFloat = 0
        private var generation = UUID()
        private var navigation: WKNavigation?

        init(parent: MarkdownBlockReader) { self.parent = parent }

        func update() {
            let newBlock = loadedID != parent.blockID
            let size = UIFontMetrics.default.scaledValue(for: 18)
            if newBlock { pendingLine = nil; requestID = nil }
            if newBlock || (parent.active && (source != parent.text || fontSize != size)) {
                generation = UUID()
                let expectedGeneration = generation
                let shouldCapture = !newBlock && ready
                ready = false
                if shouldCapture {
                    webView?.evaluateJavaScript("window.note.captureLine()") { [weak self] result, _ in
                        guard let self, self.generation == expectedGeneration else { return }
                        if self.pendingLine == nil { self.pendingLine = result as? Double }
                        self.load(size: size)
                    }
                } else { load(size: size) }
            }
            if requestID != parent.scrollRequest?.id {
                requestID = parent.scrollRequest?.id
                pendingRequest = parent.scrollRequest
                applyPosition()
            }
            if ready { webView?.evaluateJavaScript("window.note.enable(\(enabled))") }
        }

        private func load(size: CGFloat) {
            guard let webView else { return }
            loadedID = parent.blockID
            source = parent.text
            fontSize = size
            token = UUID().uuidString
            do {
                let html = try MarkdownHTML.render(source)
                navigation = webView.loadHTMLString(MarkdownHTML.page(html, token: token, fontSize: size), baseURL: nil)
            } catch { parent.error(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            ready = true
            webView.evaluateJavaScript("window.note.enable(\(enabled))")
            applyPosition()
        }

        func sourceLine(_ completion: @escaping (Double?) -> Void) {
            guard ready else { completion(pendingLine); return }
            webView?.evaluateJavaScript("window.note.captureLine()") { result, _ in completion(result as? Double) }
        }

        func show(line: Double) {
            pendingLine = line
            pendingRequest = nil
            applyPosition()
        }

        private func applyPosition() {
            guard ready, let webView else { return }
            if let line = pendingLine {
                pendingLine = nil
                webView.evaluateJavaScript("window.note.restoreLine(\(line))")
            } else if let request = pendingRequest {
                pendingRequest = nil
                if case .edge(let edge) = request.target {
                    webView.evaluateJavaScript("window.note.edge(\(edge == .bottom))")
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard parent.active, enabled, let body = message.body as? [String: Any],
                  body["token"] as? String == token, body["action"] as? String == "task",
                  let line = body["line"] as? Int, let checked = body["checked"] as? Bool,
                  source == parent.text,
                  let range = SourceLineMap(source).range(of: line) else { return }
            let regex = try! NSRegularExpression(pattern: #"(?:[-+*]|\d{1,9}[.)])[\t ]+\[([ xX])\]"#)
            let ns = source as NSString
            guard let marker = regex.firstMatch(in: source, range: range) else { return }
            let character = marker.range(at: 1)
            guard (ns.substring(with: character).lowercased() == "x") != checked else { return }
            source = ns.replacingCharacters(in: character, with: checked ? "x" : " ")
            parent.text = source
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(action.request.url == nil || action.request.url?.scheme == "about" ? .allow : .cancel) }
        }

        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
                UIMenu(children: suggested + (self?.parent.supplementalMenu?() ?? []))
            })
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.error("Markdown view failed: \(error.localizedDescription)")
        }
    }
}
