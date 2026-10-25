import AppKit
import OutboundCore
import SwiftUI

/// The window shown before Outbound is unlocked: a live window onto the world, a way to buy it that unlocks
/// by itself once paid, and a place to paste a key bought earlier.
@MainActor
final class ActivationWindow {
    private let window: NSWindow
    private let preview: PreviewView
    private let state = ActivationState()

    init(license: LicenseController, world: World, gpu: GPU) {
        let size = CGSize(width: 560, height: 300)
        preview = PreviewView(world: world, gpu: gpu, size: size)
        let view = ActivationView(license: license, preview: preview, state: state)
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Unlock Outbound"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        preview.start()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        preview.stop()
        window.close()
    }

    /// Says thank you for a moment, then gets out of the way of the wallpaper.
    func finish() {
        guard window.isVisible else {
            close()
            return
        }
        state.unlocked = true
        // Holds on to the window until it has closed; the app lets go of it straight away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { self.close() }
    }
}

@MainActor
@Observable
final class ActivationState {
    var unlocked = false
}

private struct ActivationView: View {
    @Bindable var license: LicenseController
    let preview: PreviewView
    let state: ActivationState
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewRepresentable(view: preview)
                .frame(width: 560, height: 300)
            VStack(alignment: .leading, spacing: 12) {
                Text("Outbound")
                    .font(.system(size: 22, weight: .semibold))
                if state.unlocked {
                    Label("Outbound is yours. Enjoy the flight.", systemImage: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                } else if license.waitingForPurchase {
                    waiting
                } else {
                    Text("A painted world drifting by behind your desktop, with a bird that follows your cursor.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Buy for \(Store.price)", action: license.buy)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(license.busy)
                        Text("One payment, for up to three of your Macs. Outbound unlocks by itself once you've paid.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().padding(.vertical, 4)
                HStack {
                    Text("Already bought it? Paste your license key.")
                        .font(.callout)
                    Spacer()
                    Link("Find my key", destination: Store.portalURL)
                        .font(.callout)
                }
                HStack {
                    TextField("OUTBOUND-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(unlock)
                    Button("Unlock", action: unlock)
                        .disabled(LicenseStatus.clean(key).isEmpty || license.busy)
                    if license.busy { ProgressView().controlSize(.small) }
                }
                if let message = license.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
        .frame(width: 560)
        .ignoresSafeArea(edges: .top)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for your purchase…")
                    .font(.headline)
            }
            Text("Finish paying in your browser. Outbound unlocks by itself a moment after, so there's nothing to copy.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Open Checkout Again", action: license.buy)
                Button("Cancel", action: license.cancelPurchase)
                    .buttonStyle(.link)
            }
        }
    }

    private func unlock() {
        Task { await license.activate(key) }
    }
}

private struct PreviewRepresentable: NSViewRepresentable {
    let view: PreviewView
    func makeNSView(context: Context) -> PreviewView { view }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

/// A small live view of the world, centred on the middle of the main display.
final class PreviewView: NSView {
    private let world: World
    private let gpu: GPU
    private let metal: MetalView
    private let renderer: ViewRenderer
    private var link: CADisplayLink?

    @MainActor
    init(world: World, gpu: GPU, size: CGSize) {
        self.world = world
        self.gpu = gpu
        metal = MetalView(device: gpu.device)
        renderer = ViewRenderer(gpu: gpu)
        super.init(frame: CGRect(origin: .zero, size: size))
        metal.frame = bounds
        metal.autoresizingMask = [.width, .height]
        addSubview(metal)
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func start() {
        guard link == nil else { return }
        let main = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = CGRect(x: main.midX - bounds.width / 2, y: main.midY - bounds.height / 2,
                           width: bounds.width, height: bounds.height)
        renderer.configure(frame: frame, scale: Double(NSScreen.main?.backingScaleFactor ?? 2))
        let link = metal.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @MainActor
    func stop() {
        link?.invalidate()
        link = nil
    }

    @MainActor @objc private func tick(_ link: CADisplayLink) {
        world.advance(to: link.targetTimestamp)
        guard let drawable = metal.metalLayer.nextDrawable(), let commands = gpu.queue.makeCommandBuffer() else { return }
        renderer.encode(world: world, into: drawable.texture, commandBuffer: commands)
        commands.present(drawable)
        commands.commit()
    }
}
