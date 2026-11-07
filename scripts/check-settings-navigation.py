#!/usr/bin/env python3
"""Small navigation regressions using production methods, without opening windows."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
settings = (root / 'native/Player/Modern/PlayerSettings.swift').read_text()
page = settings[settings.index('enum PlayerSettingsPage:'):]
modes = (root / 'PlayerSystem/PlayerWindowModes.swift').read_text()
route = modes[modes.index('    func showFileBrowser() {'):modes.index('    func showSidebar(_ tab:')]
fixture = r'''
final class WindowModes {
    func restore(_ model: PlayerModel, completion: () -> Void) {
        model.miniPlayer = false
        completion()
    }
}
final class PlayerModel {
    var miniPlayer = false
    var sidebarTab = "info"
    var quickSettings = true
    var queuePopover = true
    var inspector = false
    let windowModes = WindowModes()
'''+route+r'''
}
let model = PlayerModel()
model.showFileBrowser()
precondition(model.inspector && model.sidebarTab == "queue")
precondition(!model.queuePopover && !model.quickSettings)
model.showFileBrowser()
precondition(model.inspector && !model.queuePopover)
model.miniPlayer = true
model.inspector = false
model.showFileBrowser()
precondition(!model.miniPlayer && model.inspector)
precondition(PlayerSettingsPage.allCases.allSatisfy { $0.matches("  ") })
precondition(PlayerSettingsPage.playback.matches("HDR"))
precondition(PlayerSettingsPage.enhancement.matches("rife fps"))
precondition(PlayerSettingsPage.enhancement.matches("超帧"))
precondition(PlayerSettingsPage.network.matches("伺服器"))
precondition(!PlayerSettingsPage.controls.matches("RIFE"))
precondition(!PlayerSettingsPage.allCases.contains { $0.matches("no-such-option-000") })
precondition(PlayerSettingsDestination.results(for: "HDR").contains { $0.id == "playback.Picture & Color" })
precondition(PlayerSettingsDestination.results(for: "RIFE").contains { $0.id == "enhancement.Enhancement" })
precondition(PlayerSettingsDestination.results(for: "字幕").contains { $0.id == "subtitles.Tracks & Bilingual" })
precondition(PlayerSettingsDestination.results(for: "  ").count == PlayerSettingsPage.allCases.count)
precondition(PlayerSettingsDestination.results(for: "no-such-option-000").isEmpty)
precondition(Set(PlayerSettingsDestination.sections.map(\.id)).count == PlayerSettingsDestination.sections.count)
precondition(PlayerSettingsDestination.find("general.Screenshots")?.page == .general)
print("PASS: browser route, mini restore, settings categories and section destinations")
'''
out = root / 'build/checks/settings-navigation'
out.mkdir(parents=True, exist_ok=True)
swift = out / 'check.swift'
swift.write_text('import Foundation\n'+page+fixture)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(out / 'cache'), str(swift), '-o', str(out / 'check')], check=True)
subprocess.run([str(out / 'check')], check=True)
