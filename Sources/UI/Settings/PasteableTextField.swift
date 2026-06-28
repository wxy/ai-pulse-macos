import SwiftUI
import AppKit

/// NSTextField wrapper that supports Cmd+V paste (unlike vanilla SwiftUI
/// TextField with a custom Binding on macOS).
struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.delegate = context.coordinator
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PasteableTextField
        init(_ parent: PasteableTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }
    }
}
