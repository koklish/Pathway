import Foundation

/// Синхронное чтение списка веток — для контекстного меню.
///
/// Отдельный тип, а не метод GitService: тот весь асинхронный, и синхронный
/// метод посреди него выглядел бы оплошностью, а не решением.
///
/// Синхронно потому, что `NSMenuDelegate.menuNeedsUpdate` обязан вернуть
/// готовое меню: наполнить его позже нечем — AppKit к тому времени уже
/// показал то, что есть, и пустое подменю на первом клике осталось бы пустым.
///
/// Цена измерена на репозитории с 70 ветками: **76 мс на первом вызове** и
/// 8–10 мс на последующих. Первый дороже из-за холодного кеша файловой
/// системы, и эту заминку при первом открытии меню человек может заметить.
/// Плата принята: альтернатива — пустое подменю, которое наполнится к
/// следующему клику, а меню, требующее открыть его дважды, хуже короткой
/// паузы. На сетевом томе вызывающий код обязан этот метод не звать —
/// см. FileListView.addBranches: там git отвечает сотнями миллисекунд, а на
/// отвалившемся сервере может не ответить вовсе.
///
/// Разбор `.git/packed-refs` вместо процесса отвергнут: ветки лежат и
/// файлами, и упакованными, а даты пришлось бы доставать из объектов — это
/// повторение логики git в обход самого git.
public enum BranchReader {

    /// Ветки репозитория, свежие первыми; пустой массив — прочитать не вышло.
    ///
    /// Молча пустой, а не бросок: меню строится в любом случае, и показать
    /// ошибку ему всё равно негде.
    public static func branches(at repository: URL, tool: URL = URL(fileURLWithPath: "/usr/bin/git")) -> [Branch] {
        let process = Process()
        process.executableURL = tool
        process.arguments = BranchList.arguments
        process.currentDirectoryURL = repository
        process.environment = GitCLI.processEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        // Ошибки не читаем и вход глушим: список веток не спрашивает пароля, а
        // непрочитанная труба stderr при этом переполниться не может — git
        // пишет туда лишь строку-другую.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // Нет git — нет списка. Пункты операций при этом остаются: они
            // покажут внятную ошибку сами, когда их нажмут.
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            return []
        }
        return BranchList.parse(output, current: GitRepository.branch(at: repository))
    }
}
