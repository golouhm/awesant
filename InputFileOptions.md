# Awesant::Input::File

## Description

Log files as input. Log file rotation is supported, but note that
you should configure delayed compression for log files.

## Options

### path

The path to the log file. Multiple paths can be set as comma separated list.

    input {
        file {
            type syslog
            path /var/log/messages, /var/log/syslog
        }
    }

### skip

Define regexes to skip events.

    input {
        file {
            type php-error-log
            path /var/log/php/error.log
            skip PHP (Notice|Warning)
            skip ^any event$
        }
    }

Lines that match the regexes will be skipped.

### save_position

Experimental feature.

If the option save_position is set to true then the last position
with the inode of the log file is saved to a file. If Awesant is down
then it can resume its work where it was stopped. This is useful if you
want to lose as less data as possible of your log files.

Please note that this feature is experimental and does not keep log file
rotations.

