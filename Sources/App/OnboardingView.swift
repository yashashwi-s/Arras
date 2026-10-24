import SwiftUI

struct OnboardingView: View {
    @ObservedObject var manager: PhotoManager
    var finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var floatingPreview = false
    @State private var printPreview = true
    private let names = ["Welcome", "Photos", "Collages", "Layers & slideshows", "Make it yours"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("Arras").font(.system(.headline, design: .rounded))
                Spacer()
                Button("Skip tour", action: finish)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding-skip")
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 6) {
                            Text(String(format: "%02d", page + 1)).monospacedDigit()
                            Text("/ \(names.count) · \(names[page])")
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .accessibilityLabel("Step \(page + 1) of \(names.count): \(names[page])")
                        .accessibilityIdentifier("onboarding-progress")

                        pageContent.id(page)
                            .transition(.opacity)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(28)
                    .id("onboarding-content-top")
                }
                .onChange(of: page) { _, _ in proxy.scrollTo("onboarding-content-top", anchor: .top) }
            }
            Divider()
            HStack(spacing: 14) {
                if page > 0 {
                    Button("Back") { changePage(to: page - 1) }
                        .accessibilityIdentifier("onboarding-back")
                }
                Spacer()
                if page == names.count - 1 {
                    Button("Open Settings", action: finish)
                        .accessibilityIdentifier("onboarding-finish")
                    Button("Try a sample collage", action: addSample)
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.libraryRecoveryRequired)
                        .accessibilityIdentifier("onboarding-sample")
                } else {
                    Button(page == 0 ? "Take a look" : "Continue") { changePage(to: page + 1) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("onboarding-next")
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 28).padding(.vertical, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 580, minHeight: 500)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            title("Your photos.\nYour kind of desktop.", detail: "A favourite view, a few things worth keeping, a reference for what’s next. Give them a place on your Mac.")
            desktopPreview
            tip("menubar.rectangle", "Always close by", "Arras lives in your menu bar. Open Settings there, or press ⌘, while Arras is active. Closing Settings leaves your widgets in place.")
        case 1:
            title("Start with one photo.", detail: "Add files from Finder or choose images from Photos. Move a picture into place, then make the frame your own.")
            desktopPreview
            HStack {
                Text("Try a different frame").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Print frame", isOn: $printPreview).toggleStyle(.switch).fixedSize()
                    .accessibilityIdentifier("onboarding-print-preview")
            }
            tip("arrow.up.left.and.arrow.down.right", "Small details, your choice", "Drag a photo to move it. Hover a corner to resize. Appearance holds shapes, mats, shadows and tilt; Copy Appearance carries the look to another photo.")
        case 2:
            title("Together. Still individual.", detail: "A collage gives separate photos a shared background and editable captions. Nothing gets flattened into one image.")
            desktopPreview
            HStack(alignment: .top, spacing: 24) {
                tip("rectangle.3.group", "Move the group", "Drag the empty background. Lock it when the placement feels right.")
                tip("arrow.up.left.and.arrow.down.right", "Edit each photo", "Move or resize a member on its own. The collage boundary grows and shrinks with it.")
            }
        case 3:
            title("A changing view.\nA steady reference.", detail: "Let a slideshow rotate through your collection. Keep a second photo where you need it while you work.")
            desktopPreview
            HStack {
                Text("Preview a reference layer").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Preview depth", selection: $floatingPreview) {
                    Text("On Desktop").tag(false)
                    Text("Floating").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    .accessibilityLabel("Preview depth")
                    .accessibilityIdentifier("onboarding-depth-preview")
            }
            tip("square.3.layers", "Choose what stays in view", "Depth in More options places a photo above app windows or on the desktop. A collage controls depth for its whole group. Add → Create Slideshow starts a collection; double-click it to advance.")
        default:
            title("Make room for your own.", detail: "Start with an editable sample, or open Settings to add your photos. You can revisit this tour whenever you like.")
            tip("rectangle.stack", "Save before you experiment", "Setups keeps arrangements on this Mac. Export Backup makes a portable .arras file with its stored media.")
            tip("hand.raised", "Permissions when you need them", "Finder imports need no Photos access. Arras asks for Photos or Screen Recording access only when you use those features. Privacy explains the controls and any network activity.")
            Text("Before sharing your screen, hide personal widgets. Some recording apps can capture visible widgets, and browser meetings aren’t automatically detected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            #if !ARRAS_APP_STORE
            Divider()
            SupportArrasView()
            #endif
        }
    }

    private func title(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.system(size: 32, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 15)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.tint)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An in-window illustration using the same bundled photos as the real starter
    /// examples. Preview switches never mutate the library or request permissions.
    private var desktopPreview: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor))
                LinearGradient(colors: [Color(red: 0.76, green: 0.61, blue: 0.44).opacity(0.32), Color(red: 0.32, green: 0.45, blue: 0.42).opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                if page == 3 {
                    RoundedRectangle(cornerRadius: 10).fill(.background)
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.3)).frame(width: 5, height: 5) } }.padding(12)
                        }
                        .overlay { Text("Your workspace").font(.caption).foregroundStyle(.secondary) }
                        .frame(width: width * 0.48, height: 138).offset(x: -width * 0.12, y: 12)
                        .zIndex(floatingPreview ? 0 : 2)
                    photo("StarterCoast", width: width * 0.36, height: 135, printFrame: false)
                        .offset(x: width * 0.19, y: -12).zIndex(1)
                    Text(floatingPreview ? "Floating above app windows" : "On the desktop")
                        .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule()).offset(y: 91).zIndex(3)
                } else if page == 1 {
                    photo("StarterBotanical", width: 142, height: 172, printFrame: printPreview)
                        .rotationEffect(.degrees(printPreview ? -5 : 0))
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.5)) }
                        .frame(width: width * 0.76, height: 192)
                    HStack(spacing: 12) {
                        photo("StarterBotanical", width: width * 0.23, height: 138, printFrame: true)
                        VStack(spacing: 10) {
                            photo("StarterCoast", width: width * 0.35, height: 62, printFrame: false)
                            photo("StarterArchitecture", width: width * 0.35, height: 62, printFrame: false)
                        }
                    }.offset(y: -7)
                    Text(page == 2 ? "A few things worth keeping" : "A little more you.")
                        .font(.system(size: 14, weight: .medium, design: .serif)).offset(y: 78)
                }
            }
            .overlay(alignment: .topLeading) {
                Text("PREVIEW").font(.system(size: 9, weight: .medium)).tracking(1)
                    .foregroundStyle(.secondary).padding(12)
            }
        }
        .frame(height: 230)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page == 3 ? "Depth preview: \(floatingPreview ? "photo above an app window" : "photo behind an app window")" : "Sample photos arranged in \(page == 1 ? "a photo frame" : "an editable collage")")
    }

    private func photo(_ name: String, width: CGFloat, height: CGFloat, printFrame: Bool) -> some View {
        Image(name).resizable().scaledToFill()
            .frame(width: width, height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: printFrame ? 2 : 8))
            .padding(printFrame ? 6 : 0).padding(.bottom, printFrame ? 10 : 0)
            .background(printFrame ? Color(red: 0.97, green: 0.95, blue: 0.91) : .clear, in: RoundedRectangle(cornerRadius: printFrame ? 3 : 8))
            .shadow(color: .black.opacity(0.16), radius: 7, y: 4)
    }

    private func changePage(to next: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = next }
    }

    private func addSample() {
        if manager.addStarterExample(.galleryWall) {
            finish()
        } else {
            AppDialog.inform(title: "Couldn’t Add Example", message: "Your library has not changed. Try again, or open Settings to review any library or storage problem.", style: .warning)
        }
    }
}

#if !ARRAS_APP_STORE
/// A quiet opt-in purchase route, never a limit or an automatic prompt.
struct SupportArrasView: View {
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text("Arras is free and open source. Buying the App Store edition supports its development.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Link(destination: Constants.supportPurchaseURL) {
                Label("Support Arras", systemImage: "arrow.up.right")
            }
            .font(.callout).fixedSize().accessibilityIdentifier("support-arras")
            .accessibilityHint("Opens the optional App Store purchase. Your free app keeps all its features.")
        }
    }
}
#endif
