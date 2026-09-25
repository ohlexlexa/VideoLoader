// Обязательная часть расширения Safari: сам код расширения — общий с Chrome (chrome-extension/),
// build.sh кладёт его в Resources этого appex. Сообщений от расширения приложению нет,
// поэтому обработчик просто отвечает пустым ответом.

import Foundation

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
