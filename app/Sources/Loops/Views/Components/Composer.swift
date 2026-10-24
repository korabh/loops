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
        .padding(.horizontal, 16)
      HStack(alignment: .center, spacing: 8) {
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
            Image(icon: "ellipsis", size: 14)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("More ways to send")
        }
        if busy {
          ProgressView().controlSize(.small).frame(width: 26, height: 26)
        } else {
          Button(action: go) {
            Image(icon: icon, size: 13)
              .frame(width: 16, height: 16)
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(trimmed.isEmpty)
          .help("\(send) (⌘↩)")
        }
      }
      .padding(.leading, 16)
      .padding(.trailing, 7)
      .padding(.vertical, 7)
      .frame(minHeight: 40)
      .glassEffect(.regular, in: .rect(cornerRadius: 20))
      .onTapGesture { focused = true }
    }
    .frame(maxWidth: 704)
    .padding(.horizontal, 20)
    .padding(.bottom, 14)
    .padding(.top, 6)
    .frame(maxWidth: .infinity)
  }

  private func go() {
    guard !trimmed.isEmpty, !busy else { return }
    submit(trimmed)
    text = ""
  }
}
