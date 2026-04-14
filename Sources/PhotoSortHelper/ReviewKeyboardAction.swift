import AppKit

enum ReviewKeyboardAction: Equatable {
    case previousGroup
    case nextGroup
    case previousItem
    case nextItem
    case toggleKeepDiscard
    case queueForEdit

    private static let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    static func resolve(event: NSEvent) -> ReviewKeyboardAction? {
        resolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags
        )
    }

    static func resolve(
        keyCode: UInt16,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags
    ) -> ReviewKeyboardAction? {
        let normalizedModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard normalizedModifiers.intersection(disallowedModifiers).isEmpty else {
            return nil
        }

        switch keyCode {
        case 123:
            return .previousGroup
        case 124:
            return .nextGroup
        case 126:
            return .previousItem
        case 125:
            return .nextItem
        default:
            break
        }

        switch charactersIgnoringModifiers.lowercased() {
        case "`":
            return .toggleKeepDiscard
        case "e":
            return .queueForEdit
        default:
            return nil
        }
    }
}
