// LogWindowView.swift

import SwiftUI

struct LogWindowView: View {
    @EnvironmentObject var runtime: SignalRuntime
    @State private var followTail = true

    private let maxLines = 3000
    @State private var lines: [String] = []
    @State private var lastConsumedCharCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(runtime.statusLine ?? "Logs")
                    .font(.headline)

                Spacer()

                if !followTail {
                    Text("Paused")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }

                Button("Follow") { followTail = true }
                    .disabled(followTail)

                Button("Clear") {
                    runtime.logText = ""
                    lines.removeAll(keepingCapacity: true)
                    lastConsumedCharCount = 0
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines.indices, id: \.self) { i in
                            Text(lines[i])
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(i)
                        }
                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .padding(8)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0).onChanged { _ in
                        followTail = false
                    }
                )
                .onChange(of: lines.count) { _, _ in
                    guard followTail else { return }
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
        .padding()
        .onAppear {
            rebuildFromScratch(runtime.logText)
        }
        .onChange(of: runtime.logText) { _, newValue in
            consumeAppendOnly(newValue)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.linear(duration: 0.08)) {
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
        }
    }

    private func rebuildFromScratch(_ text: String) {
        lastConsumedCharCount = text.utf16.count
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines = tail(newLines, max: maxLines)
    }

    private func consumeAppendOnly(_ text: String) {
        let newCount = text.utf16.count

        if newCount < lastConsumedCharCount {
            rebuildFromScratch(text)
            return
        }

        if newCount == lastConsumedCharCount { return }

        let start = String.Index(utf16Offset: lastConsumedCharCount, in: text)
        let appended = String(text[start...])
        lastConsumedCharCount = newCount

        let appendedLines = appended.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if appendedLines.isEmpty { return }

        lines.append(contentsOf: appendedLines)

        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private func tail(_ arr: [String], max: Int) -> [String] {
        guard arr.count > max else { return arr }
        return Array(arr.suffix(max))
    }
}
