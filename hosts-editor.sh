#!/bin/zsh
# Self Service editor for /etc/hosts. Jamf runs this as root, so standard users
# can view and change their hosts entries through swiftDialog without admin rights.
#
# The file is always rewritten as three parts:
#   1. macOS's default entries (always written, never editable)
#   2. predefined blocks the user switches on or off (see BLOCKS below)
#   3. the user's own entries, validated before anything is written
# Lines another tool added outside these parts are shown as the user's own entries.
#
# Jamf parameters ($1-$3 are reserved by Jamf):
#   $4  extra protected hostname globs, comma-separated, e.g. "sso.example.com,*.corp.example.com".
#       Users cannot map these in their own entries. Blocks are not restricted.
#   $5  maximum number of custom entries (default 100)
#
# Requires swiftDialog 2.4+ (https://github.com/swiftDialog/swiftDialog).
# Environment overrides exist for testing only: HOSTS_FILE, BACKUP_DIR, LOG_FILE, DIALOG_BIN.

set -uo pipefail
setopt extended_glob

HOSTS_FILE="${HOSTS_FILE:-/private/etc/hosts}"
# The log and backups default to the console user's ~/Library; see main.
LOG_FILE="${LOG_FILE:-}"
BACKUP_DIR="${BACKUP_DIR:-}"
CONSOLE_USER=""
DIALOG_BIN="${DIALOG_BIN:-/usr/local/bin/dialog}"
BACKUPS_KEPT=10
MAX_CUSTOM="${5:-100}"
[[ $MAX_CUSTOM == <-> ]] || MAX_CUSTOM=100

# Users can never map these in their own entries: remapping them would let a user
# cut the Mac off from Apple or Jamf and so from management. Add your own with $4.
PROTECTED_PATTERNS=(
  'apple.com' '*.apple.com' 'icloud.com' '*.icloud.com'
  '*.jamfcloud.com' '*.jamf.com'
)
for p in ${(s:,:)${4:-}}; do
  p="${${p## #}%% #}"
  [[ -n $p ]] && PROTECTED_PATTERNS+=("${p:l}")
done
RESERVED_NAMES=(localhost broadcasthost)

# ---- Predefined blocks ---------------------------------------------------------
# BLOCK_IDS sets the order. The id is written into /etc/hosts as a marker, so
# renaming one switches that block off for everyone who had it on. Editing a
# block's lines takes effect for every user the next time they save.
# Lines are validated at startup; a bad block stops the script before any dialog.
typeset -a BLOCK_IDS=(staging qa local-dev)
typeset -A BLOCK_LABEL BLOCK_LINES

BLOCK_LABEL[staging]="Staging environment (app, api, auth)"
BLOCK_LINES[staging]="10.20.0.10  app.staging.example.com
10.20.0.11  api.staging.example.com
10.20.0.12  auth.staging.example.com"

BLOCK_LABEL[qa]="QA environment"
BLOCK_LINES[qa]="10.30.0.10  app.qa.example.com
10.30.0.11  api.qa.example.com"

BLOCK_LABEL[local-dev]="Local development (*.local.example.com to this Mac)"
BLOCK_LINES[local-dev]="127.0.0.1  app.local.example.com api.local.example.com
::1        app.local.example.com api.local.example.com"
# --------------------------------------------------------------------------------

DEFAULT_HOSTS=$'##\n# Host Database\n#\n# localhost is used to configure the loopback interface\n# when the system is booting.  Do not change this entry.\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost'
CUSTOM_BEGIN="# >>> custom entries (edit through Self Service)"
CUSTOM_END="# <<< custom entries"
TEXT_TITLE="Your entries"

# Shown at the top of the editor as a template. Lines that still match exactly
# are dropped on save; they are comments, so they never fail validation.
EXAMPLE_LINES=(
  '## Examples - these lines are not saved. Copy one and remove the ## to use it.'
  '## 10.1.2.3      myapp.test'
  '## 10.1.2.4      api.myapp.test admin.myapp.test   # one address, several names'
  '## fe80::1%en0   printer.test                      # IPv6 works too'
)

# The log and backups live in the console user's home so they can read them
# without admin rights. Root never writes there itself: the user controls that
# folder, and a planted symlink could aim root's writes at any file. Writing as
# the user limits every write to files they could change anyway.
as_user() {
  if [[ $EUID -eq 0 ]]; then /usr/bin/sudo -n -u "$CONSOLE_USER" -- "$@"; else "$@"; fi
}

# Appends stdin to $1 as the console user, creating its folder if needed.
user_append() {
  as_user /bin/sh -c 'umask 022; /bin/mkdir -p "${1%/*}" && /bin/cat >> "$1"' sh "$1" 2>/dev/null
}

# The unified log copy is the record users cannot edit; the file copy is for them.
log() {
  /usr/bin/logger -t hosts-editor "$*"
  [[ -n $LOG_FILE ]] && print -r -- "$(/bin/date '+%F %T') $*" | user_append "$LOG_FILE"
  print -r -- "$*" >&2
}

is_ipv4() {
  local -a octets=("${(@s:.:)1}")
  local o
  (( $#octets == 4 )) || return 1
  for o in "${octets[@]}"; do
    # No leading zeros: some resolvers read them as octal.
    [[ $o =~ '^(0|[1-9][0-9]{0,2})$' ]] && (( o <= 255 )) || return 1
  done
}

is_ipv6() {
  local a=$1 zone g
  if [[ $a == *%* ]]; then
    zone=${a#*%}; a=${a%%\%*}
    [[ $zone =~ '^[A-Za-z0-9_.-]+$' ]] || return 1
  fi
  [[ $a == *:* && $a =~ '^[0-9A-Fa-f:.]+$' ]] || return 1
  # An embedded IPv4 tail (::ffff:10.0.0.1) counts as two groups.
  if [[ $a == *.* ]]; then
    is_ipv4 "${a##*:}" || return 1
    a="${a%:*}:0:0"
  fi
  [[ $a == *:::* || $a == *::*::* ]] && return 1
  [[ $a == :[^:]* || $a == *[^:]: ]] && return 1
  local -a groups=(${(s.:.)a})
  for g in $groups; do (( ${#g} <= 4 )) || return 1; done
  if [[ $a == *::* ]]; then (( $#groups <= 7 )); else (( $#groups == 8 )); fi
}

is_hostname() {
  local h=$1 label
  (( ${#h} <= 253 )) || return 1
  local -a labels=("${(@s:.:)h}")
  for label in "${labels[@]}"; do
    [[ $label =~ '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' ]] || return 1
  done
  # An all-numeric last label is an address typed in the wrong column.
  [[ ! $labels[-1] =~ '^[0-9]+$' ]]
}

is_protected() {
  local h=${1:l} p
  for p in $PROTECTED_PATTERNS; do
    [[ $h == ${~p} ]] && return 0
  done
  return 1
}

# Appends problems to ERRORS and sets ENTRY_COUNT. $2 names the source in messages.
validate_entries() {
  local text=$1 ctx=$2 line body ip h where n=0
  local -a f
  ENTRY_COUNT=0
  for line in "${(@f)text}"; do
    (( n++ ))
    where="$ctx, line $n"
    if [[ $line == '# >>>'* || $line == '# <<<'* ]]; then
      ERRORS+=("$where: lines starting with \`# >>>\` or \`# <<<\` are reserved")
      continue
    fi
    body=${line%%\#*}
    f=(${=body})
    (( $#f )) || continue
    (( ENTRY_COUNT++ ))
    ip=$f[1]
    if (( $#f < 2 )); then
      ERRORS+=("$where: needs an IP address followed by at least one hostname")
      continue
    fi
    is_ipv4 $ip || is_ipv6 $ip || ERRORS+=("$where: \`${ip//\`/}\` is not a valid IPv4 or IPv6 address")
    for h in $f[2,-1]; do
      if ! is_hostname $h; then
        ERRORS+=("$where: \`${h//\`/}\` is not a valid hostname")
      elif (( ${RESERVED_NAMES[(Ie)${h:l}]} )); then
        ERRORS+=("$where: \`$h\` is a system entry and cannot be remapped")
      elif [[ $ctx == "$TEXT_TITLE" ]] && is_protected $h; then
        ERRORS+=("$where: \`$h\` is managed by IT and cannot be changed here")
      fi
    done
  done
}

# Strips CRs and trailing spaces, and trims blank lines from both ends.
normalize_text() {
  local -a lines=("${(@f)${1//$'\r'/}}")
  lines=("${(@)lines%%[[:space:]]#}")
  while (( $#lines )) && [[ -z $lines[1] ]]; do shift lines; done
  while (( $#lines )) && [[ -z $lines[-1] ]]; do lines[-1]=(); done
  print -r -- "${(F)lines}"
}

without_examples() {
  local -a lines=("${(@f)1}")
  lines=("${(@)lines:|EXAMPLE_LINES}")
  normalize_text "${(F)lines}"
}

# Sets ENABLED and CUSTOM_TEXT from the current hosts file.
read_current() {
  local line in_block="" norm
  local -a custom pending
  local -A default_set
  for line in "${(@f)DEFAULT_HOSTS}"; do default_set[${(j: :)${=line}}]=1; done
  ENABLED=()
  [[ -f $HOSTS_FILE ]] || { CUSTOM_TEXT=""; return; }
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -n $in_block ]]; then
      if [[ $line == "# <<< block:$in_block" ]]; then in_block=""; pending=(); else pending+=("$line"); fi
      continue
    fi
    if [[ $line =~ '^# >>> block:([A-Za-z0-9_-]+)' ]]; then
      in_block=$match[1]
      # Retired block ids are dropped along with their lines.
      (( ${BLOCK_IDS[(Ie)$in_block]} )) && ENABLED+=($in_block)
      continue
    fi
    [[ $line == "$CUSTOM_BEGIN" || $line == "$CUSTOM_END" ]] && continue
    norm="${(j: :)${=line}}"
    [[ -n $norm ]] && (( ${+default_set[$norm]} )) && continue
    custom+=("$line")
  done < "$HOSTS_FILE"
  # A block with no end marker was hand-edited: keep its lines rather than lose them.
  if [[ -n $in_block ]]; then
    log "Block ${in_block} has no end marker; keeping its lines as custom entries"
    ENABLED=(${ENABLED:#$in_block})
    custom+=("${pending[@]}")
  fi
  CUSTOM_TEXT="$(normalize_text "${(F)custom}")"
}

render_hosts() {
  local id
  print -r -- "$DEFAULT_HOSTS"
  for id in $BLOCK_IDS; do
    (( ${ENABLED[(Ie)$id]} )) || continue
    print
    print -r -- "# >>> block:$id - ${BLOCK_LABEL[$id]}"
    print -r -- "${BLOCK_LINES[$id]}"
    print -r -- "# <<< block:$id"
  done
  if [[ -n $CUSTOM_TEXT ]]; then
    print
    print -r -- "$CUSTOM_BEGIN"
    print -r -- "$CUSTOM_TEXT"
    print -r -- "$CUSTOM_END"
  fi
}

# Writes the swiftDialog JSON config. Blocks are passed as
# "id<TAB>label<TAB>0|1<TAB>lines", with no tabs inside the lines.
build_dialog_json() {
  /usr/bin/osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  const [out, message, textTitle, text, ...blocks] = argv;
  const cfg = {
    title: 'Hosts File',
    message,
    icon: 'SF=network',
    button1text: 'Save',
    button2text: 'Cancel',
    width: '900',
    height: '760',
    textfield: [{ title: textTitle, editor: true, value: text }],
  };
  if (blocks.length) {
    const parsed = blocks.map((b) => b.split('\t'));
    cfg.checkbox = parsed.map(([, label, on]) => ({ label, checked: on === '1' }));
    cfg.checkboxstyle = { style: 'switch', size: 'small' };
    // The ? button opens this over the dialog, so edits in progress are kept.
    cfg.helpmessage = parsed
      .map(([, label, , lines]) => `**${label}**\n\n` + lines.split('\n')
        .map((l) => '- `' + l.replace(/`/g, '') + '`').join('\n'))
      .join('\n\n');
  }
  const json = $.NSString.alloc.initWithUTF8String(JSON.stringify(cfg));
  if (!json.writeToFileAtomicallyEncodingError(out, true, $.NSUTF8StringEncoding, null))
    throw new Error(`cannot write ${out}`);
}
JXA
}

# Reads swiftDialog's --json output: writes the edited text to $2 and prints the
# ids of the blocks left on. Blocks are passed as "id<TAB>label".
parse_dialog_output() {
  /usr/bin/osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  const [src, textOut, textTitle, ...blocks] = argv;
  const raw = $.NSString.stringWithContentsOfFileEncodingError(src, $.NSUTF8StringEncoding, null);
  if (raw.isNil()) throw new Error(`cannot read ${src}`);
  const s = raw.js;
  // swiftDialog can print log lines around the JSON.
  const result = JSON.parse(s.slice(s.indexOf('{'), s.lastIndexOf('}') + 1));
  const text = $.NSString.alloc.initWithUTF8String(String(result[textTitle] ?? ''));
  if (!text.writeToFileAtomicallyEncodingError(textOut, true, $.NSUTF8StringEncoding, null))
    throw new Error(`cannot write ${textOut}`);
  return blocks
    .map((b) => b.split('\t'))
    .filter(([, label]) => result[label] === true || result[label] === 'true')
    .map(([id]) => id)
    .join('\n');
}
JXA
}

write_hosts() {
  local user=$1 new stamp
  new="$(/usr/bin/mktemp "${HOSTS_FILE:h}/.hosts.XXXXXX")" || return 1
  render_hosts > "$new"
  /usr/sbin/chown root:wheel "$new" 2>/dev/null || true
  /bin/chmod 644 "$new"

  if [[ -f $HOSTS_FILE ]] && /usr/bin/cmp -s "$new" "$HOSTS_FILE"; then
    /bin/rm -f "$new"
    log "No changes to ${HOSTS_FILE} by ${user}"
    return 2
  fi

  if [[ -f $HOSTS_FILE ]]; then
    stamp="$(/bin/date '+%Y%m%d-%H%M%S')"
    # Names sort by date, so everything after the newest BACKUPS_KEPT is pruned.
    as_user /bin/sh -c 'umask 077; /bin/mkdir -p "$1" && /bin/cat > "$1/hosts.$2" || exit 1
      cd "$1" && /bin/ls -1 | /usr/bin/grep "^hosts\.[0-9-]*$" | /usr/bin/sort -r \
        | /usr/bin/tail -n "+$(( $3 + 1 ))" | while read -r f; do /bin/rm -f -- "$f"; done' \
      sh "$BACKUP_DIR" "$stamp" "$BACKUPS_KEPT" < "$HOSTS_FILE" \
      || log "Could not back up ${HOSTS_FILE} to ${BACKUP_DIR}; continuing"
    /usr/bin/diff -u "$HOSTS_FILE" "$new" | user_append "$LOG_FILE"
  fi

  /bin/mv -f "$new" "$HOSTS_FILE" || { /bin/rm -f "$new"; return 1; }
  /usr/bin/dscacheutil -flushcache 2>/dev/null
  /usr/bin/killall -HUP mDNSResponder 2>/dev/null
  log "${user} updated ${HOSTS_FILE}: blocks=[${(j:,:)ENABLED}] custom entries=${ENTRY_COUNT}"
}

main() {
  if [[ $EUID -ne 0 && $HOSTS_FILE == /private/etc/hosts ]]; then
    print -r -- "Run as root (from Jamf)." >&2; return 1
  fi
  [[ -x $DIALOG_BIN ]] || { log "swiftDialog not found at ${DIALOG_BIN}"; return 1; }

  local user home
  user="$(/usr/bin/stat -f %Su /dev/console)"
  if [[ -z $user || $user == root || $user == loginwindow ]]; then
    log "No user logged in; nothing to show"; return 1
  fi
  CONSOLE_USER=$user
  home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null)"
  home=${home#NFSHomeDirectory: }
  [[ -d $home ]] || { log "Cannot find the home folder of ${user}"; return 1; }
  : ${LOG_FILE:=$home/Library/Logs/HostsEditor/hosts-editor.log}
  : ${BACKUP_DIR:=$home/Library/Application Support/HostsEditor/Backups}

  # Admin mistakes in the blocks must never reach /etc/hosts.
  local id
  local -a labels=()
  ERRORS=()
  for id in $BLOCK_IDS; do
    [[ $id =~ '^[A-Za-z0-9_-]+$' ]] || ERRORS+=("block id '$id' may only use letters, digits, _ and -")
    [[ -n ${BLOCK_LABEL[$id]:-} && -n ${BLOCK_LINES[$id]:-} ]] || { ERRORS+=("block '$id' needs a label and lines"); continue; }
    labels+=("${BLOCK_LABEL[$id]}")
    validate_entries "${BLOCK_LINES[$id]}" "block $id"
  done
  local -a unique=("${(@u)labels}")
  (( $#unique == $#labels )) || ERRORS+=("block labels must be unique")
  (( ${labels[(Ie)$TEXT_TITLE]} )) && ERRORS+=("no block may be labelled '$TEXT_TITLE'")
  if (( $#ERRORS )); then
    log "Invalid block definitions: ${(j:; :)ERRORS}"; return 1
  fi

  read_current

  local tmpdir rc
  umask 077
  tmpdir="$(/usr/bin/mktemp -d /private/var/tmp/hosts-editor.XXXXXX)" || return 1
  # swiftDialog 3 relaunches itself as the console user when run as root, so that
  # user must be able to read dialog.json. 711 lets them open it by name without
  # listing the folder or changing anything in it; the other files stay root-only.
  /bin/chmod 711 "$tmpdir"
  trap "/bin/rm -rf '$tmpdir'" EXIT

  local intro="Switch the predefined blocks on or off, and add or edit your own entries below.

One entry per line: \`IP-address hostname [more hostnames]\`. Lines starting with \`#\` are comments. The examples at the top of the editor are not saved. The macOS default entries are kept automatically."
  (( $#BLOCK_IDS )) && intro+=$'\n\n'"Press the **?** button to see what each block adds."
  local message=$intro
  local editor_text="${(F)EXAMPLE_LINES}"
  [[ -n $CUSTOM_TEXT ]] && editor_text+=$'\n\n'"$CUSTOM_TEXT"
  local -a block_args parse_args
  while true; do
    block_args=() parse_args=()
    for id in $BLOCK_IDS; do
      block_args+=("$id"$'\t'"${BLOCK_LABEL[$id]}"$'\t'"$(( ${ENABLED[(Ie)$id]} ? 1 : 0 ))"$'\t'"${BLOCK_LINES[$id]//$'\t'/ }")
      parse_args+=("$id"$'\t'"${BLOCK_LABEL[$id]}")
    done
    build_dialog_json "$tmpdir/dialog.json" "$message" "$TEXT_TITLE" "$editor_text" "${block_args[@]}" \
      || { log "Could not build the dialog"; return 1; }
    /bin/chmod 644 "$tmpdir/dialog.json"

    "$DIALOG_BIN" --jsonfile "$tmpdir/dialog.json" --json \
      > "$tmpdir/result.json" 2> "$tmpdir/dialog.err"
    rc=$?
    case $rc in
      0) ;;
      2) log "${user} cancelled; ${HOSTS_FILE} unchanged"; return 0 ;;
      # 200 and up are swiftDialog's own errors, such as a file it cannot read.
      <200->) log "swiftDialog failed (exit ${rc}): $(<"$tmpdir/dialog.err")"; return 1 ;;
      *) log "Dialog closed (exit ${rc}); ${HOSTS_FILE} unchanged"; return 0 ;;
    esac

    ENABLED=(${(f)"$(parse_dialog_output "$tmpdir/result.json" "$tmpdir/text" "$TEXT_TITLE" "${parse_args[@]}")"}) \
      || { log "Could not read the dialog result"; return 1; }
    # Validate the text as the user sees it, so line numbers in errors match the
    # editor, and show it back unchanged if anything needs fixing.
    editor_text="$(<"$tmpdir/text")"
    editor_text=${editor_text//$'\r'/}
    CUSTOM_TEXT="$(without_examples "$editor_text")"

    ERRORS=()
    validate_entries "$editor_text" "$TEXT_TITLE"
    (( ENTRY_COUNT > MAX_CUSTOM )) && ERRORS+=("you have ${ENTRY_COUNT} entries; the limit is ${MAX_CUSTOM}")
    (( $#ERRORS )) || break

    local shown=("${(@)ERRORS[1,10]}")
    message="$intro

**Nothing was saved. Fix these and press Save again:**
${(F)${(@)shown/#/- }}"
    (( $#ERRORS > 10 )) && message+=$'\n'"- …and $(( $#ERRORS - 10 )) more"
  done

  write_hosts "$user"
  rc=$?
  case $rc in
    0) "$DIALOG_BIN" --mini --title "Hosts File" --icon "SF=checkmark.circle" \
         --message "Your hosts file has been updated." --button1text OK --timer 10 >/dev/null 2>&1 ;;
    2) "$DIALOG_BIN" --mini --title "Hosts File" --icon "SF=network" \
         --message "No changes to save." --button1text OK --timer 10 >/dev/null 2>&1; rc=0 ;;
    *) log "Failed to write ${HOSTS_FILE}" ;;
  esac
  return $rc
}

# Sourcing the script (for tests) loads the functions without running anything.
[[ $ZSH_EVAL_CONTEXT == toplevel ]] && { main "$@"; exit $?; }
