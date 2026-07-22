import AppKit
import SwiftUI

/// Невидимый слой под содержимым окна: ловит клики, не доставшиеся ни одному
/// контролу, — по отступам, фону, статус-бару. Нужен, чтобы клик «в пустое место»
/// снимал фокус с адресной строки, как в Проводнике и Finder.
struct ClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? CatcherView)?.onClick = onClick
    }

    private final class CatcherView: NSView {
        var onClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            onClick()
            super.mouseDown(with: event)
        }
    }
}
