# Configuration syntax

The main configuration file of Awesant is

    /etc/awesant/agent/main.conf

The configuration format is very simple:

    param1 value
    param2 value
    param3 " value value value "
    param4 ' value value value '
    param5 multiline \
           value
    param6 " multiline values " \
           " with whitespaces "

    section1 {
        param1 value
        param2 value

        subsection1 {
            param1 value
            param2 value
        }
    }

## Comments

Add comments to the configuration to explain parameter:

    # Comment
    param1 value # comment
    param2 value#value # comment
    param3 'value \# value' # comment
    param4 multiline \ # comment
           value
    param5 " multiline values " \ # comment
           " with whitespaces " # comment

## Hashes and arrays

Please not that if a hash key exists that the values will be pushed into an array:

    param1 value
    param2 value1
    param2 value2

    section1 {
        param value
    }
    section2 {
        param value
    }
    section2 {
        param value
    }

is

    param1 => "value",
    param2 => [ "value1", "value2" ],
    section1 => { param => "value" },
    section2 => [
        { param => "value" },
        { param => "value" }
    ]

## Include

It's possible to include configuration files.

    param1 value
    param2 value
    include /etc/awesant/agent/another-config.conf
    param3 value

Or include directories.

    foo {
        include /etc/awesant/agent/conf.d
    }

Relative paths are possible too. The base path is the path to the main configuration file.

    /etc/awesant/agent/main.conf    # the first loaded configuration file
    /etc/awesant/agent/foo.conf
    /etc/awesant/agent/foo/bar.conf
    /etc/awesant/agent/conf.d/

    section {
        include foo.conf
        include foo/bar.conf
        include conf.d
    }

'include conf.d' - that would load all configuration files that ends with .conf.
