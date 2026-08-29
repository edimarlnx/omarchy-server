# Server variant of config/increase-lockout-limit.sh.
#
# /etc/pam.d/system-auth is upstream-owned and the changes are insertions, not
# full-file overrides, so they stay scripted. The three seds upstream runs on
# /etc/pam.d/sddm-autologin are dropped: there is no display manager on a
# server, so that file does not exist and sed would fail the script.
sed -i 's|^\(auth\s\+required\s\+pam_faillock.so\)\s\+preauth.*$|\1 preauth silent deny=10 unlock_time=120|' \
  /etc/pam.d/system-auth
sed -i 's|^\(auth\s\+\[default=die\]\s\+pam_faillock.so\)\s\+authfail.*$|\1 authfail deny=10 unlock_time=120|' \
  /etc/pam.d/system-auth
