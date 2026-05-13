# claudefuel — secondary cast for README
# Stacks three bar renders, one per profile, so the per-profile awareness
# is visible at a glance: each bar has its own [profile] label and its own
# usage values, demonstrating that CLAUDE_CONFIG_DIR isolates everything.
#
# Render:  vhs docs/assets/multi-account.tape
# Output:  docs/assets/multi-account.gif

Output docs/assets/multi-account.gif

Set Shell zsh
Set FontSize 14
Set Width 1300
Set Height 380
Set Theme "Catppuccin Mocha"
Set TypingSpeed 0ms
Set PlaybackSpeed 1.0
Set Padding 20

# Hidden setup: silence the prompt for the demo helper invocations so the
# focus stays on the bars themselves, and clear the screen.
Hide
Type "clear"
Enter
Show

Sleep 600ms

# Profile 1 — work: light usage, fresh session.
Type "docs/assets/_demo-bar.sh work 40000 35 50 1200"
Enter
Sleep 2800ms

# Profile 2 — personal: mid-session, weekly nearly capped.
Type "docs/assets/_demo-bar.sh personal 140000 65 88 4500"
Enter
Sleep 2800ms

# Profile 3 — oss: heavy context use, but light rate-limit consumption.
Type "docs/assets/_demo-bar.sh oss 185000 22 31 800"
Enter
Sleep 4500ms
