import AppKit
import OutboundCore
import SwiftUI

/// The window shown before Outbound is unlocked: a live window onto the world, a way to buy it that unlocks
/// by itself once paid, and a place to paste a key bought earlier. Once unlocked it stays to say where Outbound
/// lives now, and offers to open it at login. A copy from the App Store was bought there, so its window opens at
/// that last step, once, on the first launch.
@MainActor
final class ActivationWindow {
    private let window: NSWindow
    private let preview: PreviewView
    private let state = ActivationState()
    private var observer: NSObjectProtocol?
    /// Called once the window is closed after unlocking, when it is no longer needed.
    var onDone: () -> Void = {}
    /// Whether the preview has the pale border, as the wallpaper does.
    var paperEdge: Bool {
        get { preview.paperEdge }
        set { preview.paperEdge = newValue }
    }

    private static let size = CGSize(width: 560, height: 300)

    #if APPSTORE
    init(world: World, gpu: GPU) {
        preview = PreviewView(world: world, gpu: gpu, size: Self.size)
        window = Self.makeWindow()
        set(up: ActivationView(preview: preview, state: state) { [weak self] size in
            self?.fit(size)
        } done: { [weak self] in
            self?.window.performClose(nil)
        }, title: String(localized: "Welcome to Outbound"))
    }
    #else
    init(license: LicenseController, world: World, gpu: GPU) {
        preview = PreviewView(world: world, gpu: gpu, size: Self.size)
        window = Self.makeWindow()
        set(up: ActivationView(license: license, preview: preview, state: state) { [weak self] size in
            self?.fit(size)
        } done: { [weak self] in
            self?.window.performClose(nil)
        }, title: String(localized: "Unlock Outbound"))
    }
    #endif

    private static func makeWindow() -> NSWindow {
        NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                 backing: .buffered, defer: false)
    }

    private func set(up view: some View, title: String) {
        let hosting = NSHostingController(rootView: view)
        // The window follows its content itself: AppKit only ever grows it, and adds the title bar the content
        // already runs under.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // The content is a fixed size, whatever it is offered.
        window.setFrame(CGRect(origin: .zero, size: hosting.sizeThatFits(in: .zero)), display: false)
        window.title = title
        window.showsOnlyCloseButton()
        window.titlebarAppearsTransparent = true
        window.opensWhereTheUserIs()
        window.isReleasedWhenClosed = false
        window.center()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
    }

    func show() {
        #if !APPSTORE
        // Locked again, say after a refund, while the thank-you was still up.
        state.unlocked = false
        #endif
        preview.start()
        window.bringForward()
    }

    #if !APPSTORE
    /// Says thank you and where to find Outbound, and stays until the buyer is done reading. Someone who closed
    /// the window, or never saw it, isn't shown it again.
    func finish() {
        guard window.isVisible else {
            preview.stop()
            onDone()
            return
        }
        state.opensAtLogin = true
        state.unlocked = true
    }
    #endif

    /// Fits the window to its content as it changes, keeping the top edge where it is.
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != window.frame.size else { return }
        window.setFrame(CGRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width,
                               height: size.height), display: true, animate: window.isVisible)
    }

    private func closed() {
        preview.stop()
        guard state.unlocked else { return }
        // What the box showed when the window went away, however it was closed.
        LoginItem.set(state.opensAtLogin)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        onDone()
    }
}

@MainActor
final class ActivationState: ObservableObject {
    #if APPSTORE
    // Opens at login only if the user ticks the box: the App Store asks that apps never start at login unasked.
    @Published var unlocked = true
    @Published var opensAtLogin = false
    #else
    @Published var unlocked = false
    @Published var opensAtLogin = true
    #endif
}

private struct ActivationView: View {
    #if !APPSTORE
    @ObservedObject var license: LicenseController
    #endif
    let preview: PreviewView
    @ObservedObject var state: ActivationState
    let resized: (CGSize) -> Void
    let done: () -> Void
    #if !APPSTORE
    @State private var key = ""
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewRepresentable(view: preview)
                .frame(width: 560, height: 300)
            VStack(alignment: .leading, spacing: 12) {
                Text("Outbound")
                    .font(.system(size: 22, weight: .semibold))
                #if APPSTORE
                unlocked
                #else
                if state.unlocked {
                    unlocked
                } else {
                    locked
                }
                #endif
            }
            .padding(22)
        }
        .frame(width: 560)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
        .ignoresSafeArea(edges: .top)
    }

    #if !APPSTORE
    @ViewBuilder private var locked: some View {
        if license.waitingForPurchase {
            waiting
        } else {
            Text("A painted world behind your desktop, and a bird that follows your cursor.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Buy for \(Store.price)", action: license.buy)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(license.busy)
                Text("$4.99 + tax, once. Up to 3 Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Divider().padding(.vertical, 4)
        HStack {
            Text("Already bought it? Paste your key.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
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
    #endif

    @ViewBuilder private var unlocked: some View {
        #if APPSTORE
        Label("All set. Thank you!", systemImage: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.green)
        #else
        Label("Unlocked. Thank you!", systemImage: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.green)
        #endif
        Text("Outbound is flying behind your windows now. It lives in the menu bar, under \(Image(nsImage: .outboundGullInline).renderingMode(.template)).")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Divider().padding(.vertical, 4)
        HStack {
            Toggle("Open Outbound at login", isOn: $state.opensAtLogin)
            Spacer()
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    #if !APPSTORE
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for your purchase…")
                    .font(.headline)
            }
            Text("Finish paying in your browser. Outbound unlocks by itself.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Open Checkout", action: license.buy)
                Button("Cancel", action: license.cancelPurchase)
                    .buttonStyle(.link)
            }
        }
    }

    private func unlock() {
        Task { await license.activate(key) }
    }
    #endif
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
    private var link: FrameClock?

    /// Whether the painting has its pale border, as the wallpaper does.
    @MainActor var paperEdge: Bool {
        get { renderer.paperEdge }
        set { renderer.paperEdge = newValue }
    }

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
        let display = (window?.screen ?? NSScreen.main)?.displayID ?? CGMainDisplayID()
        let link = FrameClock(view: metal, display: display) { [weak self] tick in self?.tick(tick) }
        link.rate = 30
        self.link = link
    }

    @MainActor
    func stop() {
        link?.invalidate()
        link = nil
    }

    @MainActor private func tick(_ tick: FrameClock.Tick) {
        world.advance(to: tick.targetTimestamp)
        guard let drawable = metal.metalLayer.nextDrawable(), let commands = gpu.queue.makeCommandBuffer() else { return }
        renderer.encode(world: world, into: drawable.texture, commandBuffer: commands)
        commands.present(drawable)
        commands.commit()
    }
}
