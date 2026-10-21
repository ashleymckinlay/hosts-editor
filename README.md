# Hosts Editor

A Jamf Self Service policy that lets standard users view and change `/etc/hosts` without admin rights. Jamf runs `hosts-editor.sh` as root, and the script shows a swiftDialog window with:

- **Predefined blocks**, shown as on/off switches. IT defines these in the script, for example staging or QA environments. The **?** button lists each block's entries. It opens over the dialog, so the user doesn't lose edits in progress.
- **Your entries**, an editor that starts with the user's current entries. A few `##` example lines sit at the top as a template. They are never saved, and a user can copy one and remove the `##` to use it. Edit them in `EXAMPLE_LINES`.

Nothing is written until every line is valid. If a line is wrong, the dialog opens again with the user's text still there and a list of what to fix.

## Deploying
1. Install swiftDialog 2.4 or later with its own Jamf policy, or as part of this one.
2. Edit the `BLOCK_IDS`, `BLOCK_LABEL` and `BLOCK_LINES` section of `hosts-editor.sh` to set up your blocks. Replace the `example.com` samples.
3. Upload the script to Jamf. Create a Self Service policy that runs it, and set:
   - **Parameter 4**: more protected hostname globs, comma-separated, such as `sso.example.com,*.corp.example.com`.
   - **Parameter 5**: the most custom entries a user may have. The default is 100.

## How the file is managed
Each save rewrites `/etc/hosts` in three parts:

1. The macOS default entries for `localhost` and `broadcasthost`. The script always writes these, and users cannot change them.
2. Each block that is switched on, between `# >>> block:<id>` and `# <<< block:<id>` markers. The script uses these markers to tell which blocks are on. If you change a block's lines, the change reaches each user the next time they save.
3. The user's own entries, between the `custom entries` markers.

Lines that other tools added outside these parts are shown to the user as their own entries, so nothing is lost. Blocks whose id is no longer in the script are removed.

## Validation
- Each line must be `IP hostname [hostname…]`, with an optional `# comment`. Lines starting with `#` are comments.
- IPv4 addresses must have four octets from 0 to 255, without leading zeros. IPv6 is supported, including `::` shorthand, zone ids such as `fe80::1%en0`, and embedded IPv4.
- Hostnames must follow RFC 1123. Each label is 1–63 letters, digits or hyphens, the full name is at most 253 characters, and the last label cannot be all digits.
- `localhost` and `broadcasthost` cannot be remapped.
- Users cannot map protected names: `apple.com`, `icloud.com`, `*.jamfcloud.com` and `*.jamf.com`, plus anything in parameter 4. This stops a user from cutting the Mac off from management. Blocks are written by IT, so this rule does not apply to them.
- The script checks the block definitions before it shows the dialog. If a block is invalid, it logs the error and exits, so a mistake by IT never reaches users.

## Audit and recovery
- Every change is logged with the console user's name to the unified log (`log show --predicate 'senderImagePath CONTAINS "logger"' | grep hosts-editor`) and to `/var/log/hosts-editor.log`, which also records a diff of each change.
- The previous 10 versions are kept in `/Library/Management/HostsEditor/backups/`, readable by root only.
- After each write, the script flushes the DNS cache.

## Limits
This tool only controls what the Self Service flow writes. A user with admin rights, or another root process, can still edit `/etc/hosts` directly.

## Testing
Sourcing the script loads its functions without running anything. To run the whole flow on a copy of the file, point `HOSTS_FILE`, `STATE_DIR` and `LOG_FILE` somewhere else, and set `DIALOG_BIN` to a stub that prints swiftDialog-style JSON.
