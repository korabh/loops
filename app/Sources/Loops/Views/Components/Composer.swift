import SwiftUI

struct ComposerAction {
  let title: String
  let run: (String) -> Void
}

struct Composer<Status: View>: View {
  let prompt: String
  var send = "Send"
  var icon = "arrow.up"
  var busy = false
  var more: [ComposerAction] = []
  let submit: (String) -> Void
  @ViewBuilder var status: Status
  @State private var text = ""
  @FocusState private var focused: Bool

  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      status
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
      HStack(spacing: 8) {
        TextField(prompt, text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .focused($focused)
          .onSubmit(go)
        if !more.isEmpty, !trimmed.isEmpty {
          Menu {
            ForEach(more.indices, id: \.self) { i in
              Button(more[i].title) {
                more[i].run(trimmed)
                text = ""
              }
            }
          } label: {
            Label { Text("More Ways to Send") } icon: { Image(icon: "ellipsis", size: 14) }
          }
          .labelStyle(.iconOnly)
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("More ways to send")
        }
        if busy {
          ProgressView().controlSize(.small).frame(width: 26, height: 26)
        } else {
          Button(action: go) {
            Label { Text(send) } icon: { Image(icon: icon, size: 13).frame(width: 16, height: 16) }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(trimmed.isEmpty)
          .help("\(send) (⌘↩)")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .glassEffect()
      .onTapGesture { focused = true }
    }
    .scenePadding()
  }

  private func go() {
    guard !trimmed.isEmpty, !busy else { return }
    submit(trimmed)
    text = ""
  }
}
