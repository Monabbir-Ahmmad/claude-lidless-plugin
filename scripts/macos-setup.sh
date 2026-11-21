#!/bin/sh
# Lidless: one-time setup for macOS. Run it yourself with sudo. /lidless-setup
# prints the exact command with the full path of this file:
#
#   sudo sh <plugin folder>/scripts/macos-setup.sh          install
#   sudo sh <plugin folder>/scripts/macos-setup.sh remove   uninstall
#
# It installs two small files and nothing else:
#   /etc/sudoers.d/lidless_<you>   lets your account run exactly
#                                  "pmset -a disablesleep 0" and "pmset -a disablesleep 1"
#                                  without a password
#   /Library/LaunchDaemons/com.tajbir.lidless.reset.plist
#                                  runs "pmset -a disablesleep 0" at every boot, so
#                                  sleep is back to normal before anyone logs in
set -e

PLIST=/Library/LaunchDaemons/com.tajbir.lidless.reset.plist

if [ "$(id -u)" != 0 ]; then
  echo "This needs root. Run it with sudo:"
  echo "  sudo sh \"$0\" $*"
  exit 1
fi

user=${SUDO_USER:-}
case $user in
  ''|root|*[!A-Za-z0-9._-]*)
    echo "Could not tell which account to set up. Run this with sudo from your own account, not from a root shell."
    exit 1
    ;;
esac

# sudo ignores files in sudoers.d whose name contains a dot.
SUDOERS=/etc/sudoers.d/lidless_$(printf '%s' "$user" | tr '.' '_')

if [ "${1:-}" = remove ] || [ "${1:-}" = uninstall ]; then
  /usr/bin/pmset -a disablesleep 0 > /dev/null 2>&1 || true
  launchctl bootout system "$PLIST" > /dev/null 2>&1 || true
  rm -f "$SUDOERS" "$PLIST"
  echo "Removed the Lidless sudo rule and the boot-time reset. Lid-close sleep is switched back on."
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
  echo "# Lidless: lets $user switch lid-close sleep off and on. Nothing else."
  echo "$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
} > "$tmp"
# Never install a sudoers file that does not parse.
visudo -cf "$tmp" > /dev/null
install -m 0440 -o root -g wheel "$tmp" "$SUDOERS"

cat > "$PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.tajbir.lidless.reset</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/pmset</string>
    <string>-a</string>
    <string>disablesleep</string>
    <string>0</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST_EOF
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

echo "Lidless setup is done."
echo "  Sudo rule:        $SUDOERS"
echo "  Boot-time reset:  $PLIST (takes effect from the next boot)"
echo "You can now use /lidless in Claude Code."
