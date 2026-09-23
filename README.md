# Control MuteMe LED lighting from the command line on Mac.

```
Control the MuteMe LED via hidapitester.
Device: 3603:0001 serial 100225 (from /Users/rob.becker/.muteme.cfg)

Usage: mm <command> [effect] [seconds]

Commands:
  <color> [effect] [seconds]   Set a color: red, green, yellow, blue, purple, cyan, white
  processing [seconds]         Pulsing yellow  (Claude Code: working)
  success [seconds]            Pulsing green   (Claude Code: done)
  needinput [seconds]          Pulsing red     (Claude Code: needs input)
  party [seconds]              Cycle through a rainbow (default 10 seconds), then turn off
  off                          Turn the LED off
  start                        (Re)start MuteMe-Client.app and hand the LED back to it
  stop                         Quit MuteMe-Client.app without changing the LED
  detect                       Find the MuteMe, flash it white, save it to ~/.muteme.cfg
  test                         Step through every option, asking whether each one worked
  help, -h, --help             Show this help

Effects (default: solid):
  solid              Full brightness
  dim                Low brightness
  pulse              Fast pulse
  slowpulse          Slow pulse

Seconds (whole number): turn the LED off after that long. Returns immediately and
turns off in the background (except party, which runs in the foreground). Without
seconds the LED stays on until the next command. Slow pulse is kept alive by a
background re-send every 4 seconds. Any later command cancels background work.

Every command except help quits MuteMe-Client.app first, because it holds the
device open. Run 'mm start' to give the LED back to the app.

Examples:
  mm green
  mm red pulse
  mm cyan slowpulse 10
  mm success 5
  mm party 8
```
