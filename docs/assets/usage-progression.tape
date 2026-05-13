# claudefuel — primary cast for README
# Drives statusline.sh through a usage progression so the bar visibly evolves
# (green -> orange -> yellow -> red) in place. The animation script owns the
# entire recording — the prompt and command line never make it into the gif.
#
# Render:  vhs docs/assets/usage-progression.tape
# Output:  docs/assets/usage-progression.gif

Output docs/assets/usage-progression.gif

Set Shell zsh
Set FontSize 14
Set Width 1300
Set Height 680
Set Theme "Catppuccin Mocha"
Set TypingSpeed 0ms
Set PlaybackSpeed 1.0
Set Padding 20

# Type and fire the animation inside Hide. The script's first action is a 250ms
# sleep + screen clear, so by the time Show engages the prompt is gone and the
# script is producing only bar frames.
Hide
Type "./docs/assets/_demo-animate.sh"
Enter
Sleep 350ms
Show

# 6 frames × 1.5s + 3s hold ≈ 12.25s. A little buffer in case of jitter.
Sleep 13s
