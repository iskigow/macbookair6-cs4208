# Security

This repository ships a kernel module, so bugs in it run with kernel
privileges. If you find a problem that could be exploited (for example
memory corruption reachable from user space or from a plugged device),
please do not open a public issue. Report it privately through GitHub:
"Security" tab → "Report a vulnerability". You should get an answer
within a week.

Ordinary bugs (no sound, wrong mic selected, build failures) are not
security issues: please open a normal issue.

Fixes that also affect the Linux kernel driver will be reported to the
kernel security team following `Documentation/process/security-bugs.rst`.

## Supported versions

Only the latest release tag and `main` receive fixes.
