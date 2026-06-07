import AppKit
import SwiftTerm

/// A terminal view that adds the standard macOS clipboard shortcuts.
///
/// Because FloatyTerm is a menu-less accessory app, the system doesn't route
/// ⌘C/⌘V/⌘A to the terminal automatically (there's no Edit menu to carry the
/// key equivalents). We handle them here instead.
///
/// Note: ⌘C is the *copy* shortcut and is independent of Ctrl-C, which still
/// sends SIGINT to the running program as usual.
final class FloatyTerminalView: LocalProcessTerminalView {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, flags == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers {
        case "c":
            // Only intercept ⌘C when text is actually selected, so we never
            // clobber the clipboard with an empty string when nothing is picked.
            if selectedRange().length > 0 {
                copy(self)
                return true
            }
            return super.performKeyEquivalent(with: event)
        case "v":
            paste(self)
            return true
        case "a":
            selectAll(nil)
            return true
        case "z":
            // There's no document-style undo in a terminal. This triggers zsh's
            // line-editor `undo` widget (default-bound to Ctrl-_, byte 0x1F),
            // which reverts edits to the command you're currently typing.
            send([0x1F])
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
