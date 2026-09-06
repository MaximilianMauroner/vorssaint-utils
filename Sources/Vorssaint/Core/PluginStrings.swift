// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

/// Plugin copy uses English until reviewed translations are available.
enum PluginStrings {
    static let title = "Plugins"
    static let importPackage = "Import Plugin…"
    static let empty = "No plugins installed"
    static let choose = "Select a plugin to see its commands and settings."
    static let trust = "Plugins run code on your Mac with your user account's access. They can read files, use the network, and start programs. The access listed below describes Vorssaint APIs only. It does not limit what the plugin can do. Only enable code from an author you trust."
    static let review = "Review Plugin"
    static let enable = "Trust and Enable"
    static let disabled = "Disabled"
    static let enabled = "Enabled"
    static let update = "Import Update…"
    static let rollback = "Restore Previous Version"
    static let rollbackNote = "The previous version will be restored and disabled. Review it before enabling."
    static let remove = "Remove Plugin…"
    static let deleteData = "Also delete this plugin's settings and stored data"
    static let retainData = "Settings and stored data are kept unless you select the option below."
    static let installNote = "Import installs this version in a disabled state. Enabling requires a separate trust review."
}
