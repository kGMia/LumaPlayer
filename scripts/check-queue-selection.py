#!/usr/bin/env python3
"""Run the production Play Next ordering method without launching the player."""
from pathlib import Path
import os, subprocess
root = Path(__file__).resolve().parents[1]
source = (root / 'PlayerSystem/PlayQueueActions.swift').read_text()
method = source[source.index('    func playNextQueueItems('):source.index('    func removeQueueItems(')]
fixture = r'''
import Foundation
struct Item { let id: Int64; let current: Bool }
final class PlayerModel {
    var queue = [Item(id: 1, current: true), Item(id: 2, current: false), Item(id: 3, current: false), Item(id: 4, current: false)]
    var customQueueOrder: [Int64] = []
    var queueSort = "custom"
    func synchronizeQueueOrder() {}
METHOD
}
let model = PlayerModel()
model.playNextQueueItems([4, 2, 4, 999, 1])
precondition(model.customQueueOrder == [1, 4, 2, 3])
model.queue = [Item(id: 2, current: false), Item(id: 3, current: false), Item(id: 4, current: false)]
model.playNextQueueItems([4, 2])
precondition(model.customQueueOrder == [4, 2, 3])
print("PASS: selected order, duplicate/stale IDs, current-item exclusion, no-current insertion")
'''.replace('METHOD', method)
out = root / 'build/checks/queue-selection'
out.mkdir(parents=True, exist_ok=True)
(out / 'check.swift').write_text(fixture)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(out / 'cache'), str(out / 'check.swift'), '-o', str(out / 'check')], env=env, check=True)
subprocess.run([str(out / 'check')], check=True)
