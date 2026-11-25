import AppKit
import Carbon

/// The keyboard layout in use, so Cmd+V is posted on the key that types "v" whatever the layout.
enum KeyboardLayout {
    /// Positions on the keyboard (virtual key codes), the same on every layout.
    static let ansiV: UInt32 = 9
    static let delete: UInt16 = 51

    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: chars, count: length)
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
        }
    }

    static func keyCode(typing character: String) -> UInt32? {
        (0..<128).first { self.character(for: UInt32($0))?.lowercased() == character }.map(UInt32.init)
    }
}
