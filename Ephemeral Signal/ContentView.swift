//ContentView.swift

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var runtime: SignalRuntime

    private let minW: CGFloat = 100
    private let minH: CGFloat = 100

    var body: some View {
        Group {
            if runtime.isStarting {
                LogWindowView()
            } else {
                WebView(url: runtime.webURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: minW, minHeight: minH)
    }
}
