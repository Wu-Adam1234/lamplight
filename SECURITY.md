# Security

On macOS, Lamplight asks for administrator rights once, to install a single sudoers rule. That makes the
lid-closed feature the part worth scrutinising, so here is exactly what it does.

## What gets installed (macOS)

`/etc/sudoers.d/lamplight`, mode `0440`, owned by `root:wheel`, containing one line:

```
<your-account> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

- Only your account, only `/usr/bin/pmset`, only those exact arguments. sudo refuses any other
  arguments, so the rule can't be used to change other power settings or run anything else.
- Your account name is checked against `^[A-Za-z_][A-Za-z0-9._-]{0,63}$` (and `ALL` is refused) before it goes anywhere
  near the file or a shell. Other names are refused and lid-closed mode stays off.
- The line is written to a root-owned temp file and checked with `visudo -cf`. It's then installed
  under a dotted name (which sudo ignores) and moved into place in one atomic step, so a half-written
  file can never break sudo. The temp files are removed whatever happens.
- While sleep is switched off, a small watchdog process waits for Lamplight to exit and switches it
  back on, so even a crash or a force-quit restores normal sleep within seconds.
- The install command is passed straight to `do shell script … with administrator privileges`.
  No script file on disk is run as root, so nothing can swap one in between writing and running.

## What it means for you

Any process running as your user can switch lid sleep off or on without a password. It can't do
anything else with the rule. If that trade isn't right for you, choose **Not Now**, or remove the
rule from the menu (**Remove Lid-Closed Permission…**) or with `sudo rm /etc/sudoers.d/lamplight`.

## Windows

The Windows app asks for no admin rights. While it's on, it runs the built-in `powercfg` tool to set the
current power plan's lid action to "Do nothing" (`SUB_BUTTONS LIDACTION 0`, plugged in and on battery),
and sets your previous values back when it turns off. Only the integers 0 to 3 are ever passed, as
separate arguments, never through a shell.

While the lid setting is changed, a hidden `powershell.exe` helper waits for Lamplight to exit and then
restores your values, in case Lamplight crashes or is ended from Task Manager. The script it runs is
built from integers only (your two saved values and Lamplight's process ID).

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(**Security → Report a vulnerability**) rather than a public issue. You'll get a reply within a week.
