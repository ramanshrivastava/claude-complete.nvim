Output assets/demo.gif
Set Shell "bash"
Set FontSize 16
Set Width 1120
Set Height 600
Set Padding 20
Set Theme "Catppuccin Mocha"

Hide
Type "nvim -u demo/init.lua demo/sample.ts"
Enter
Sleep 4s
Show

Type "12G"
Sleep 700ms
Type "o"
Sleep 600ms
Ctrl+G
Sleep 1s
Wait+Screen@45s /parsed/
Sleep 1200ms
Tab
Sleep 2500ms
Escape
Sleep 1200ms
