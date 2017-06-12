# Awesant::Input::OracleAlertLogXml

## Description

 
Oracle Alert XML log files as input. Log file rotation is supported, but note that
you should configure delayed compression for log files.

Input XML structure of alert log:
```
        <msg time='2016-01-01T05:09:20.742+01:00' org_id='oracle' comp_id='rdbms'
         type='UNKNOWN' level='16' host_id='my.dot.com' pid='5887'
    	host_addr='3.4.5.6'>
        <txt>opidrv aborting process L002 ospid (5887) as a result of ORA-65535
        </txt>
        </msg>
```
is converted to JSON msg in the following format:
```
{"org_id":"oracle","host_addr":"3.4.5.6","time":"2016-01-01T05:09:20.742+01:00","comp_id":"rdbms","level":"16","type":"UNKNOWN","host_id":"my.dot.com","pid":"5887","txt":"opidrv aborting process L002 ospid (5887) as a result of ORA-65535\n "}
```

Also the TNS messages spread across multiple XML messages are joined together into single message:
```
{"txt":"\n***********************************************************************\n \nFatal NI connect error 12170.\n \n  VERSION INFORMATION:\nTNS for Linux: Version 11.2.0.4.0 - Production\nOracle Bequeath NT Protocol Adapter for Linux: Version 11.2.0.4.0 - Production\nTCP/IP NT Protocol Adapter for Linux: Version 11.2.0.4.0 - Production\n   Time: 02-JAN-2016 09:55:23\n   Tracing not turned on.\n   Tns error struct:\n     ns main err code: 12535\n     \n TNS-12535: TNS:operation timed out\n     ns secondary err code: 12560\n     nt main err code: 505\n     \n TNS-00505: Operation timed out\n     nt secondary err code: 110\n     nt OS err code: 0\n   Client address: (ADDRESS=(PROTOCOL=tcp)(HOST=1.2.3.4)(PORT=25397))\n ","host_id":"example.com","type":"UNKNOWN","level":"16","comp_id":"rdbms","time":"2016-01-02T09:55:23.995+01:00","host_addr":"4.5.6.7","org_id":"oracle"} 
```

## Options

### path

The path to the log file. Multiple paths can be set as comma separated list.

    input {
        file {
            type alertlog
            path /u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml
        }
    }
    
Wildcards can also be used which is ideal if multiple Oracle instances are running
on the same server.

    input {
        file {
            type alertlog
            path /u01/app/oracle/diag/rdbms/*/*/alert/log.xml
        }
    }

### skip

Define regexes to skip Oracle alert messages.

    input {
        file {
            type alertlog
            path /u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml
            skip ORA-0404(0|1)
            skip ^ORA-00600
        }
    }

Lines that match the regexes will be skipped.

### grep

Define regexes to filter Oracle alert messages.

    input {
        file {
            type alertlog
            path /u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml
            grep ORA-0404(0|1)
            grep ^ORA-00600
        }
    }

Lines that do not match the regexes will be skipped.


### save_position

Experimental feature.

If the option save_position is set to true then the last position
with the inode of the log file is saved to a file. If Awesant is down
then it can resume its work where it was stopped. This is useful if you
want to lose as less data as possible of your log files.

Please note that this feature is experimental and does not keep log file
rotations.

