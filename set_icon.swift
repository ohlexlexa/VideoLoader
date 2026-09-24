import AppKit

// Ставит приложению «свою» иконку, как через «Свойства» в Finder: такую иконку macOS
// в тёмном режиме не перекрашивает (в отличие от иконки из бандла).
let app = CommandLine.arguments[1]
let image = NSImage(contentsOfFile: CommandLine.arguments[2])!
exit(NSWorkspace.shared.setIcon(image, forFile: app, options: []) ? 0 : 1)
