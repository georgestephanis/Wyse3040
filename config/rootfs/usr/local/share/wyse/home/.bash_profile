[ -f ~/.bashrc ] && . ~/.bashrc

# Start the kiosk session on tty1. If X exits or fails you land at a shell
# here (useful while we're still building this; may be locked down later).
# Booting with "wyse.nox" on the kernel command line skips X.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ] && ! grep -qw wyse.nox /proc/cmdline; then
  startx -- -nolisten tcp >"$HOME/.xsession.log" 2>&1
fi
