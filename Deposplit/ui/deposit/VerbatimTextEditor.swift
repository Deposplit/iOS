import SwiftUI
import UIKit

/// A multi-line field that keeps exactly what was typed. `TextEditor` can turn off autocorrection
/// and capitals, but not the rest of what a keyboard does to prose: straight quotes become the
/// keyboard language's typographic ones, two hyphens become a dash, and spaces appear or vanish
/// around a paste. Typing `"it's--x"` into a `TextEditor` on a German keyboard yields `„it‘s—x“`.
/// SwiftUI has no modifier for any of that, and `UITextView` has one for each, so this is the
/// representable the SwiftUI-only rule allows for.
struct VerbatimTextEditor: UIViewRepresentable {
    @Binding var text: String
    let minHeight: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainer.lineFragmentPadding = 0

        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.mathExpressionCompletionType = .no
        textView.writingToolsBehavior = .none
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        // Only when it differs: assigning resets the caret, and the usual update is this view's
        // own keystroke coming back through the binding.
        if textView.text != text { textView.text = text }
    }

    // Grows with its text, as TextEditor does in a Form, and is never shorter than minHeight — the
    // text view itself, not a frame around it, so a tap anywhere in that height lands in the field.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(minHeight, fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
