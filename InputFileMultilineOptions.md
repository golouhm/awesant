# Awesant::Input::FileMultiline

## Description

Log files as input. Log file rotation is supported, but note that
you should configure delayed compression for log files.

## Options

### path

The path to the log file. Single file can be listed here

    input {
        file {
            type alertlog
            path /inputs/alert.log
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

### multiline_mode

=head3 indented

This mode groups multiline messages together according the following rule:
- non indented row marks the start of a multiline message
- all indented line that follow are a part of this same message
- this multiline message ends when either a non indented row is read or 10 seconds have 
  passed since the last read  

	
=head3 indented_group

This mode groups multiline messages together according the following rule:
- non indented that matches multiline_prefix marks the start of a multiline message
- all indented lines that follow are a part of this same message
- next non indented row is also part of this message if it matches multiline_indented_group
  including all indented lines that follow
- this multiline message ends when either a non indented row not matching 
  multiline_indented_group is read or 10 seconds have passed since the last read  

Parameters:
    multiline_prefix = regular expression eg "\\*{71}"
    multiline_indented_group = regular expression eg "TNS.*|Fatal NI connect error.*"
	multiline_drop_garbage = yes|no|1|0

Comment:
This mode was explicitly crafted for parsing Oracle alertlog files which includes sqlnet
messages. 

=head3 prefix-garbage
This mode groups multiline messages together according the following rule:
- multiline message starts when multiline_prefix is found
- multiline message ends when either a new multiline_prefix is found or
  multiline_garbage has been matched or 
  10 seconds have passed since the last read 
- if multiline_drop_garbage was specified non matching lines are skipped
   
Parameters:
	multiline_prefix = regular expression eg "<Msg.*"
	multiline_garbage = regular expression eg "TNS.*"
	multiline_drop_garbage = yes|no|1|0

=head3 prefix-suffix
This mode groups multiline messages together according the following rule:
- multiline message starts when multiline_prefix is found
- multiline message ends when multiline_suffix is found

	multiline_prefix
	multiline_suffix
	multiline_drop_garbage

