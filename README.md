# Clipboard

Windows' clipboard history (Win+V) for macOS, part of Love Suite. Hold ⌘V to open the list of
your latest copies: text, rich text, links, pictures and files. Let go of ⌘ to paste, or keep ⌘ down and
press V again to go down the list. Copies that password managers mark, and copies made in the apps you
ignore, are never recorded. While it runs, Spotlight's own clipboard history is off; it comes back as you
had it when Clipboard quits, or through Suite Guard should Clipboard vanish.

Install: `brew install --cask love-suite/tap/clipboard` (once the first release is out).

Development: `swift build`, `swift test`, `scripts/make-app.sh` (Swift 6.4.2, macOS 13 or later).
