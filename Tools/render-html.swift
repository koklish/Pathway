#!/usr/bin/env swift

// Рендерит HTML-файл в PNG заданного размера.
//
// Используется для фона окна DMG: макет свёрстан в HTML, и проще отрисовать его
// как есть, чем повторять градиенты руками в графическом редакторе.

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5 else {
    FileHandle.standardError.write(Data("Использование: render-html.swift <input.html> <output.png> <ширина> <высота>\n".utf8))
    exit(1)
}

let inputURL = URL(fileURLWithPath: args[1])
let outputPath = args[2]
guard let width = Int(args[3]), let height = Int(args[4]), width > 0, height > 0 else {
    FileHandle.standardError.write(Data("Ширина и высота должны быть положительными числами\n".utf8))
    exit(1)
}

guard let html = try? String(contentsOf: inputURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("Не удалось прочитать \(inputURL.path)\n".utf8))
    exit(1)
}

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let outputPath: String
    let width: Int
    let height: Int

    init(width: Int, height: Int, outputPath: String) {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                            configuration: WKWebViewConfiguration())
        self.outputPath = outputPath
        self.width = width
        self.height = height
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: height)
        config.snapshotWidth = NSNumber(value: width)

        webView.takeSnapshot(with: config) { image, error in
            guard let image, error == nil,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("Снимок не получился: \(error?.localizedDescription ?? "?")\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: self.outputPath))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Не удалось записать \(self.outputPath): \(error)\n".utf8))
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let renderer = Renderer(width: width, height: height, outputPath: outputPath)
renderer.webView.loadHTMLString(html, baseURL: inputURL.deletingLastPathComponent())

app.run()
