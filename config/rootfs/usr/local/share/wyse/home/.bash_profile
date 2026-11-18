[ -f ~/.bashrc ] && . ~/.bashrc

# Start the kiosk session on tty1. If X exits or fails you land at a shell
# here (useful while we're still building this; may be locked down later).
# Booting with "wyse.nox" on the kernel command line skips X.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ] && ! grep -qw wyse.nox /proc/cmdline; then
  # Autologin can beat udev to the GPU: i915 loads ~15 s into boot, and until
  # udev sets card0's group, X dies with "Permission denied".
  _n=0
  while [ ! -w /dev/dri/card0 ] && [ "$_n" -lt 15 ]; do sleep 1; _n=$((_n + 1)); done
  startx -- -nolisten tcp >"$HOME/.xsession.log" 2>&1
fi
