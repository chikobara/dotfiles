# Proton Pass

Proton Pass integrates the Proton Pass CLI with the Noctalia launcher, letting
you browse vaults, copy passwords, and display time-based one-time codes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lucasoe/proton-pass` |
| Entry | Launcher provider: `proton-pass` |
| Launcher Prefix | `/pass` |

## Requirements

Install `proton-pass-cli` and authenticate it with `pass-cli login` before
using the provider. The `pass-cli` executable must be available on `PATH`.

## Usage

Open the Noctalia launcher and type `/pass` to list Proton Pass vaults. Select
a vault, continue typing to filter its items, and activate an item to copy its
password to the clipboard. When the item has a TOTP secret, the current code is
also displayed in a notification.

## Notes

Vault metadata is cached only in the plugin process for the current session.
Secret values are requested from the authenticated CLI when you activate an
item; passwords are copied to the clipboard and TOTP codes are shown through
Noctalia notifications.
