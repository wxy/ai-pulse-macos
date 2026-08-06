import SwiftUI
import AppKit

// MARK: - Custom NSTextField

/// NSTextField subclass that shows a partially masked value when it does NOT
/// have focus (e.g. `sk-ant-api...••••••••`), and the full text when focused.
/// Paste / copy work normally because it's a plain NSTextField — not the
/// heavily-restricted NSSecureTextField.
final class MaskedTextField: NSTextField {
    /// The real (unmasked) text. `stringValue` may differ when masking is active.
    var actualText: String = ""

    /// When true the field is showing a masked representation.
    var isShowingMasked = false

    /// Unmask whenever the field gains focus — more reliable than the
    /// delegate callback in a SwiftUI NSViewRepresentable context.
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if isShowingMasked {
            isShowingMasked = false
            stringValue = actualText
        }
        return true
    }

    // Ctrl+A/C/V are handled by Coordinator's local NSEvent monitor (installMonitor),
    // which fires before performKeyEquivalent would — no override needed here.
}

// MARK: - SwiftUI wrapper

// Free function so it isn't tainted by NSTextField's @MainActor inheritance.
private func maskedVersion(of text: String) -> String {
    guard !text.isEmpty else { return "" }
    let show = min(8, text.count)
    let prefix = String(text.prefix(show))
    let remaining = text.count - show
    let bulletCount = min(remaining, 12)
    let bullets = bulletCount > 0 ? String(repeating: "•", count: bulletCount) : ""
    return prefix + bullets
}

/// Text field with partial masking: shows e.g. `sk-ant-api...••••••••` when
/// not focused, reveals the full value when the user clicks into it.
///
/// Paste, copy, select-all, and delete all work because this uses a plain
/// `NSTextField` — no `NSSecureTextField` restrictions.
struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> MaskedTextField {
        let tf = MaskedTextField()
        tf.placeholderString = placeholder
        tf.delegate = context.coordinator
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.cell?.wraps = false
        tf.cell?.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        context.coordinator.installMonitor(for: tf)
        // Apply initial text state
        context.coordinator.applyTextState(to: tf, bindingValue: text, isFocused: false)
        return tf
    }

    func updateNSView(_ nsView: MaskedTextField, context: Context) {
        // Only update when the binding value differs from actualText
        if nsView.actualText != text {
            let wasFocused = nsView.currentEditor() != nil
            context.coordinator.applyTextState(to: nsView, bindingValue: text, isFocused: wasFocused)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate, @unchecked Sendable {
        let parent: PasteableTextField
        nonisolated(unsafe) private var monitor: Any?

        init(_ parent: PasteableTextField) { self.parent = parent }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }

        // ---- Focus / masking helpers ----

        func applyTextState(to tf: MaskedTextField, bindingValue: String, isFocused: Bool) {
            tf.actualText = bindingValue
            if isFocused {
                // Show full text while editing
                tf.isShowingMasked = false
                tf.stringValue = bindingValue
            } else if bindingValue.isEmpty {
                tf.isShowingMasked = false
                tf.stringValue = ""
            } else {
                // Show masked version when not focused
                tf.isShowingMasked = true
                tf.stringValue = maskedVersion(of: bindingValue)
            }
        }

        // ---- Local event monitor (Ctrl+A, Ctrl+C/V for Windows users) ----

        func installMonitor(for textField: MaskedTextField) {
            if let m = monitor { NSEvent.removeMonitor(m) }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak textField] event in

                guard let tf = textField,
                      let chars = event.charactersIgnoringModifiers,
                      chars.count == 1
                else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                // Not this field's turn — let the event pass through so the
                // monitor for the actually-focused field (or default handling)
                // gets a chance. Each row installs its own monitor, and a
                // `nil` return here would stop the whole chain for everyone.
                guard tf.currentEditor() != nil else { return event }

                // ---- Ctrl+A → Select All ----
                if flags.contains(.control), !flags.contains(.command),
                   chars == "a" || chars == "A" {
                    tf.currentEditor()?.selectAll(nil)
                    return nil
                }

                // ---- Copy / Paste (Cmd or Ctrl, no Shift/Option) ----
                guard flags.contains(.command) || flags.contains(.control),
                      !flags.contains(.shift), !flags.contains(.option)
                else { return event }

                let isCopy  = (chars == "c" || chars == "C")
                let isPaste = (chars == "v" || chars == "V")
                guard isCopy || isPaste else { return event }

                if isCopy { tf.currentEditor()?.copy(nil) } else { tf.currentEditor()?.paste(nil) }
                return nil
            }
        }

        // ---- NSTextFieldDelegate ----

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let tf = obj.object as? MaskedTextField else { return }
            // Unmask: show the real text for editing
            tf.isShowingMasked = false
            tf.stringValue = tf.actualText
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? MaskedTextField else { return }
            // Save the edited text
            tf.actualText = tf.stringValue
            parent.text = tf.actualText
            // Re-mask if non-empty
            if !tf.actualText.isEmpty {
                tf.isShowingMasked = true
                tf.stringValue = maskedVersion(of: tf.actualText)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? MaskedTextField else { return }
            // While editing (unmasked), keep the binding in sync
            if !tf.isShowingMasked {
                tf.actualText = tf.stringValue
                parent.text = tf.actualText
            }
        }
    }
}
