import SwiftUI
import UIKit

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }  // @case SE-scene
    }
}

// ホストアプリの最初の画面。ユニットテストの実行中にも表示されるので、body の中の式は到達する。
struct ContentView: View {
    @State private var model = CounterModel()
    @State private var text = ""
    @State private var isOn = false  // @case S2-state

    var body: some View {
        VStack {  // @case SE-view-body
            // S1: View の body の中の if（View のテストが無いので Survived）
            if model.count > 0 {  // @case S1
                Text("count: \(model.count)")
            } else {
                EmptyView()
            }
            BadgeView(count: model.count, showsZero: isOn)
            // S2: 修飾子の引数
            TextField("name", text: $text).disabled(text.count < 3)  // @case S2-disabled
            Toggle("on", isOn: $isOn).opacity(isOn ? 1 : 0.5)  // @case S2-opacity
            SampleViewControllerRepresentable()
        }
    }
}

struct SampleViewControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SampleViewController { SampleViewController() }  // @case SE-representable
    func updateUIViewController(_ uiViewController: SampleViewController, context: Context) {}
}

final class SampleViewController: UIViewController {
    override func viewDidLoad() {  // @case EB-viewDidLoad
        super.viewDidLoad()  // @case R3
        view.backgroundColor = .systemBackground
    }
}
