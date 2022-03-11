MacOS Notification for Command Line
=====================================

Tough work:
- https://stackoverflow.com/questions/70585123/throwing-a-macos-notification-from-a-minimal-standalone-objective-c-program
- https://github.com/norio-nomura/usernotification
- https://gist.github.com/rsattar/ed74982428003db8e875
- https://github.com/julienXX/terminal-notifier
- https://github.com/xiaozhuai/macos-alert

```
Usage:
    notify -body <text> [options]

Options:
    -title <text>       Set title of notification.
    -subtitle <text>    Set subtitle of notification.
    -body <text>        Set message of notification.
    -icon <file>        Set icon of notification.
    -sound <name>       Play system sound for notification.
                        See files in "/System/Library/Sounds".

    -id <text>
        Set id of notification.
        Previous notification of the same id will be updated.
    -timeout <seconds>
        Set duration of notification.
        The default timeout is none (0).
    -command <command>
        Run a shell script when the notification is clicked.
        Timeout will be set to 180 when timeout is 0.
    -bundle <id>
        Pretend to be another application.
        Use the application's icon as badge icon of notification.
```

Simply run `./compile` to build this tool.

'nuff said.
