import AppKit
import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle requires the controller to be retained by something — we keep a
/// strong reference here and the AppDelegate keeps a strong reference to us.
///
/// Configuration lives in Info.plist:
///   - `SUFeedURL` — appcast.xml URL (GH Pages)
///   - `SUPublicEDKey` — ed25519 public key (base64) for signature verification
///   - `SUEnableAutomaticChecks` — false (user opted for manual-only checks)
///
/// Logs Sparkle lifecycle events through our `Logger` so a user submitting a bug
/// report has the update-check timeline alongside the rest of the app log.
public final class UpdateController: NSObject {
    private var controller: SPUStandardUpdaterController!

    public override init() {
        super.init()
        // `startingUpdater: true` performs initial scheduling work even though
        // automatic checks are disabled — it sets up the feed URL, prepares the
        // user-driver for showing modal UI, and validates the public key.
        // We pass `self` as both updaterDelegate (logging) and userDriverDelegate
        // (focus management — see standardUserDriverWillShowModalAlert below).
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        log("Sparkle initialized. Feed: \(controller.updater.feedURL?.absoluteString ?? "<none>")", tag: "Update")
    }

    /// Triggered by the menu-bar «Check for Updates…» item.
    /// Shows Sparkle's modal UI: «You're up to date» / new-version dialog /
    /// network-error dialog. Blocks the menu-bar app's main thread only while
    /// the modal sheet is up; downloads happen in background.
    public func checkForUpdates() {
        log("Manual update check requested", tag: "Update")
        // Activate the app right now so the menu-bar process is in the foreground
        // when Sparkle eventually shows its modal (~1 s later, after network fetch).
        // This is best-effort — the network round-trip can let other apps steal
        // focus before the modal appears, so we ALSO re-activate from the
        // userDriverDelegate hook below for a hard guarantee.
        NSApp.showDock()
        controller.checkForUpdates(nil)
    }
}

// MARK: - SPUUpdaterDelegate (logging)

extension UpdateController: SPUUpdaterDelegate {
    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("Update available: \(item.versionString) (\(item.displayVersionString))", tag: "Update")
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log("No update available (already on latest)", tag: "Update")
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log("Update check aborted: \(error.localizedDescription)", tag: "Update")
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        log("Installing update to \(item.versionString) — app will relaunch", tag: "Update")
    }
}

// MARK: - SPUStandardUserDriverDelegate (focus management)

extension UpdateController: SPUStandardUserDriverDelegate {
    /// Sparkle calls this immediately before presenting any modal alert
    /// (update available / no updates / network error / etc.). For a menu-bar
    /// accessory app, the bare modal opens BEHIND whatever app currently owns
    /// the front (Safari, Chrome, etc.) — the user sees nothing and thinks the
    /// menu item did nothing. We force activation here so the modal lands on
    /// top of the active Space.
    public func standardUserDriverWillShowModalAlert() {
        log("Sparkle modal about to show — activating app", tag: "Update")
        NSApp.showDock()  // activationPolicy=.regular + activate(ignoringOtherApps:)
        NSApp.activate(ignoringOtherApps: true)
    }
}
