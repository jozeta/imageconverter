import SwiftUI
import ImageconverterCore

/// The About window's update section: Check Now, the "when the app starts" checkbox and the status line.
struct AboutUpdateSection: View {
    @Bindable var updates: UpdateController

    var body: some View {
        VStack(spacing: LadaGlass.Spacing.s) {
            Button("Check Now") { updates.checkNow() }
                .buttonStyle(.lg(.secondary))
                .disabled(updates.isBusy)
                .accessibilityLabel("Check for updates now")
            Toggle("Check for updates when the app starts", isOn: $updates.checkOnLaunch)
                .toggleStyle(.checkbox)
                .font(LadaGlass.Typography.body)
            if let text = updates.statusText {
                Text(verbatim: text)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(updates.isFailure ? LadaGlass.Colors.badText : LadaGlass.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}

/// "Version X is available": the release notes as plain text, Install and Relaunch, Later.
struct UpdateOfferSheet: View {
    @Bindable var updates: UpdateController
    let release: UpdateRelease

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text(verbatim: "Version \(release.version) is available").font(LadaGlass.Typography.body.weight(.semibold))
            Text(verbatim: "You have \(AppInfo.version). The update is downloaded from github.com, checked (checksum, "
                 + "Developer ID signature, notarization) and replaces this app; the old one goes to the Trash.")
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                // Plain text on purpose: release notes are never rendered as Markdown or links.
                Text(verbatim: release.notes.isEmpty ? "No release notes." : release.notes)
                    .font(LadaGlass.Typography.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(LadaGlass.Spacing.s)
            .lgSurface()
            .accessibilityLabel("Release notes")
            if let text = updates.statusText, updates.status != .available(release.version) {
                Text(verbatim: text)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(updates.isFailure ? LadaGlass.Colors.badText : LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case let .downloading(received, total) = updates.status, total > 0 {
                ProgressView(value: Double(received), total: Double(total))
            }
            HStack {
                Button("Later") { updates.later() }
                    .buttonStyle(.lg(.ghost))
                    .keyboardShortcut(.cancelAction)
                    .disabled(updates.status == .installing)
                Spacer()
                if case .installedWithNote = updates.status {
                    Button("Relaunch") { updates.relaunch() }
                        .buttonStyle(.lg(.primary))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Install and Relaunch") { updates.install() }
                        .buttonStyle(.lg(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(updates.isBusy)
                }
            }
        }
        .padding(LadaGlass.Spacing.l)
        .frame(width: 440)
        .lgSheetSurface()
        .interactiveDismissDisabled(updates.isBusy)
    }
}

/// Asked once, at the first launch: nothing goes online before a yes.
struct UpdateLaunchQuestion: View {
    let updates: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("Check for updates automatically?").font(LadaGlass.Typography.body.weight(.semibold))
            Text("imageconverter can ask github.com for a newer version each time it starts. Like any web request, it "
                 + "shows GitHub your IP address and standard HTTP headers; the app adds only its version, nothing "
                 + "about you or your images. Check Now in About imageconverter always works, and you can change this there.")
                .font(LadaGlass.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("No") { updates.answerLaunchQuestion(false) }
                    .buttonStyle(.lg(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Don't check for updates automatically")
                Button("Yes") { updates.answerLaunchQuestion(true) }
                    .buttonStyle(.lg(.primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Check for updates when the app starts")
            }
        }
        .padding(LadaGlass.Spacing.l)
        .frame(width: 420)
        .lgSheetSurface()
        .interactiveDismissDisabled()
    }
}

extension View {
    /// The main window's update sheets: the first-launch question, or a release found by the launch check. Held back
    /// while the interrupted-batch sheet is up (one sheet at a time).
    func updateSheets(_ updates: UpdateController, blocked: Bool) -> some View {
        sheet(item: Binding(get: { blocked ? nil : updates.mainSheet },
                            set: { if $0 == nil, updates.mainSheet == .offer { updates.later() } })) { sheet in
            switch sheet {
            case .launchQuestion: UpdateLaunchQuestion(updates: updates)
            case .offer:
                if let release = updates.offer { UpdateOfferSheet(updates: updates, release: release) }
            }
        }
    }

    /// The About window's offer sheet, after Check Now found a release.
    func aboutUpdateSheet(_ updates: UpdateController) -> some View {
        sheet(isPresented: Binding(get: { updates.offer != nil && updates.offerInAbout },
                                   set: { if !$0 { updates.later() } })) {
            if let release = updates.offer { UpdateOfferSheet(updates: updates, release: release) }
        }
    }
}
