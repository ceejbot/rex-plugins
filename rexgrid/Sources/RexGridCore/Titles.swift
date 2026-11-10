import Foundation

/// Turning terminal titles into steady, readable names.
///
/// Agents animate their titles. Codex leads with a braille spinner frame and
/// blinks `[ ! ]` while it waits; Grok writes `⚠ Action Required - ⠴ - …`
/// and puts its current phase first; Claude Code leads with `◑` or `✳`.
/// Shown raw, a cell's text would change several times a second.
public enum Titles {
    /// Rex names an untitled tab `Window` plus eight hex digits.
    public static func isPlaceholder(_ label: String) -> Bool {
        guard label.hasPrefix("Window "), label.count == 15 else { return false }
        return label.dropFirst(7).allSatisfy(\.isHexDigit)
    }

    /// Removes animated and attention prefixes from the front of a title.
    public static func steady(_ title: String) -> String {
        let markers = ["[ ! ]", "[ . ]", "Action Required"]
        var rest = Substring(title)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            if let first = rest.first, first.isSymbol, !first.isASCII, rest.dropFirst().first?.isWhitespace != false {
                // A lone glyph standing apart from the text: a braille or
                // "◑" spinner frame, "⚠", Claude Code's "✳". ASCII is left
                // alone so "~/src" and "+page" survive.
                rest = rest.dropFirst()
            } else if let marker = markers.first(where: { rest.hasPrefix($0) }) {
                rest = rest.dropFirst(marker.count)
            } else if let first = rest.first, "-|·".contains(first), rest.dropFirst().first?.isWhitespace == true {
                // A separator left behind by a removed prefix. Requiring a
                // space after it leaves titles like "-zsh" alone.
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The part of a title that names the session, without the parts the cell
    /// already shows elsewhere: the app name and the current status message.
    ///
    /// `Waiting for response… - fooble - grok` with app `grok` and that
    /// message becomes `fooble`.
    public static func name(title: String, app: String, message: String?) -> String {
        let steadied = steady(title)
        var parts = steadied
            .replacingOccurrences(of: " | ", with: " - ")
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        while parts.count > 1, let last = parts.last, last.caseInsensitiveCompare(app) == .orderedSame {
            parts.removeLast()
        }
        if let message, parts.count > 1, let first = parts.first, sameText(first, message) {
            parts.removeFirst()
        }
        return parts.joined(separator: " · ")
    }

    /// Makes text safe to write to a terminal: control and invisible
    /// formatting characters become spaces.
    ///
    /// Titles, directory names, and messages come from whatever program is
    /// running in a pane. Printed raw, an escape sequence in one of them
    /// would be obeyed by the terminal showing `--dump` or `--watch` output.
    /// The panel itself draws text, so it isn't affected.
    public static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: " "
            default: scalar
            }
        }))
    }

    /// Whether two strings say the same thing, ignoring a trailing ellipsis.
    private static func sameText(_ a: String, _ b: String) -> Bool {
        func bare(_ text: String) -> String {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")).lowercased()
        }
        return bare(a) == bare(b)
    }
}
