// R1, «лишнее» у Safari: процесс с WKWebView, который играет звук через свой com.apple.WebKit.GPU.
// Если tap на WebKit.GPU другого приложения (Safari, Handy…) слышит этот звук — группа по bundle id смешивает
// звук всех приложений на WebKit.
//   swiftc -O scripts/webkit-audio-probe.swift -o .build/webkit-audio-probe && .build/webkit-audio-probe <wav> <секунд> <громкость 0..1>
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count >= 2, let wav = try? Data(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    print("usage: webkit-audio-probe file.wav [seconds] [volume]")
    exit(1)
}
let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 60 : 60
let volume = arguments.count > 3 ? arguments[3] : "0.1"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let configuration = WKWebViewConfiguration()
configuration.mediaTypesRequiringUserActionForPlayback = []
let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 120),
                      styleMask: [.borderless], backing: .buffered, defer: false)
let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
window.contentView!.addSubview(webView)
window.orderFrontRegardless()
let html = """
<html><body><audio id="a" autoplay loop src="data:audio/wav;base64,\(wav.base64EncodedString())"></audio>
<script>const a=document.getElementById('a'); a.volume=\(volume); a.play().then(()=>document.title='playing').catch(e=>document.title='blocked '+e);</script>
</body></html>
"""
webView.loadHTMLString(html, baseURL: nil)
print("webkit-audio-probe pid=\(getpid()) seconds=\(seconds) volume=\(volume)")
DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("page title: \(webView.title ?? "-")") }
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
setvbuf(stdout, nil, _IOLBF, 0)
app.run()
