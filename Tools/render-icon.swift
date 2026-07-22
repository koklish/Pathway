#!/usr/bin/env swift

// Рендерит Resources/AppIcon.svg в PNG нужного размера.
//
// Внешних конвертеров (rsvg, inkscape) в системе нет, поэтому рисуем через WebKit:
// он понимает SVG целиком — с градиентами, фильтрами и тенью, — и результат
// совпадает с макетом пиксель в пиксель.

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("Использование: render-icon.swift <input.svg> <output.png> <размер>\n".utf8))
    exit(1)
}

let inputPath = args[1]
let outputPath = args[2]
guard let size = Int(args[3]), size > 0 else {
    FileHandle.standardError.write(Data("Размер должен быть положительным числом\n".utf8))
    exit(1)
}

guard let svg = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("Не удалось прочитать \(inputPath)\n".utf8))
    exit(1)
}

// Прозрачный фон и нулевые отступы: иконка должна занимать весь холст.
let html = """
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;padding:0;background:transparent}
  svg{display:block;width:\(size)px;height:\(size)px}
</style></head><body>\(svg)</body></html>
"""

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let outputPath: String
    let size: Int

    init(size: Int, outputPath: String) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        self.outputPath = outputPath
        self.size = size
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: size, height: size)
        // Снимок в точке 1:1 — масштабирование делаем размером самого SVG.
        config.snapshotWidth = NSNumber(value: size)

        webView.takeSnapshot(with: config) { image, error in
            guard let image, error == nil else {
                FileHandle.standardError.write(Data("Снимок не получился: \(error?.localizedDescription ?? "?")\n".utf8))
                exit(1)
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("Не удалось закодировать PNG\n".utf8))
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

let renderer = Renderer(size: size, outputPath: outputPath)
renderer.webView.loadHTMLString(html, baseURL: nil)

app.run()
