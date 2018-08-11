#!/bin/sh
# the next line restarts using tclsh \
        exec tclsh "$0" "$@"

set resolvedArgv0 [file dirname [file normalize $argv0/___]];  # Trick to resolve last symlink
set appname [file rootname [file tail $resolvedArgv0]]
set rootdir [file normalize [file dirname $resolvedArgv0]]
foreach module [list toclbox disque] {
    foreach search [list lib/$module ../common/$module] {
        set dir [file join $rootdir $search]
        if { [file isdirectory $dir] } {
            ::tcl::tm::path add $dir
        }
    }
}
foreach search [list lib/modules] {
    set dir [file join $rootdir $search]
    if { [file isdirectory $dir] } {
        ::tcl::tm::path add $dir
    }
}

package require Tcl 8.6
package require toclbox
package require disque
set prg_args {
    -help       ""               "Print this help and exit"
    -verbose    "* DEBUG"        "Verbosity specification for program and modules"
    -nodes      "localhost:7711" "List of remote Disque servers to connect to"
    -exts       "%prgdir%/exts"  "Path to plugins directory"
    -routes     ""               "Topic routing: default is direct mapping of ALL reqs!"
    -poll       "100"            "Job polling frequency, in ms"
    -chunk      "1"              "Max number of jobs to get from each queue"
}


# ::help:dump -- Dump help
#
#       Dump help based on the command-line option specification and
#       exit.
#
# Arguments:
#	hdr	Leading text to prepend to help message
#
# Results:
#       None.
#
# Side Effects:
#       Exit program
proc ::help:dump { { hdr "" } } {
    global appname
    
    if { $hdr ne "" } {
        puts $hdr
        puts ""
    }
    puts "NAME:"
    puts "\t$appname - Ingests Disque jobs"
    puts ""
    puts "USAGE"
    puts "\t${appname}.tcl \[options\]"
    puts ""
    puts "OPTIONS:"
    foreach { arg val dsc } $::prg_args {
        puts "\t[string range ${arg}[string repeat \  10] 0 10]$dsc (default: ${val})"
    }
    exit
}
# Did we ask for help at the command-line, print out all command-line options
# described above and exit.
toclbox pullopt argv opts
if { [toclbox getopt opts -help] } {
    ::help:dump
}

# Extract list of command-line options into array that will contain program
# state.  The description array contains help messages, we get rid of them on
# the way into the main program's status array.
array set D2A {
    plugins {}
}
foreach { arg val dsc } $prg_args {
    set D2A($arg) $val
}
for { set eaten "" } {$eaten ne $opts } {} {
    set eaten $opts
    foreach opt [array names D2A -*] {
        toclbox pushopt opts $opt D2A
    }
}
# Remaining args? Dump help and exit
if { [llength $opts] > 0 } {
    ::help:dump "[lindex $opts 0] is an unknown command-line option!"
}
# Setup program verbosity and arrange to print out how we were started if
# relevant.
toclbox verbosity {*}$D2A(-verbose)
set startup "Starting $appname with following options\n"
foreach {k v} [array get D2A -*] {
    append startup "\t[string range $k[string repeat \  10] 0 10]: $v\n"
}
toclbox debug DEBUG [string trim $startup]

# Possibly read nodes and routes information from files instead, since these
# might get big
toclbox offload D2A(-routes) 3 "routes"
toclbox offload D2A(-nodes) 1 "nodes"


proc ::job { cmd id } {
    global D2A

    set cmd [string tolower $cmd]
    switch -glob -- $cmd {
        "ack*" {
            $D2A(disque) ackjob $id
        }
        "work*" {
            $D2A(disque) working $id
        }
        "nack*" {
            $D2A(disque) nack $id
        }
    }
}


# ::debug -- Slave debug helper
#
#       This procedure is aliased into the slave interpreters. It arranges to
#       push the name of the "package" (in that case the source of the plugin)
#       at the beginning of the arguments. This is usefull to detect which
#       plugin is sending output and to select output from specific plugins in
#       larger projects via the -verbose command-line option.
#
# Arguments:
#	pkg	Name of package (will be name of plugin)
#	msg	Message
#	lvl	Debug level
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::debug { pkg msg {lvl "DEBUG"}} {
    toclbox log $lvl $msg $pkg
}



# ::plugin:init -- Initialise plugin facility
#
#       Loops through the specified routes to create and initialise
#       the requested plugins.  Each plugin filename will lead to the
#       creation of a safe interpreter with the same name.  The
#       content of the file will be sourced in the interpreter and the
#       interpreter will be donated commands "debug" and "job".
#
# Arguments:
#	disque	Identifier of Disque connection
#
# Results:
#       List of created slave interpreters
#
# Side Effects:
#       None.
proc ::plugin:init { d } {
    global D2A
    
    set slaves [list]
    foreach { queue route options } $D2A(-routes) {
        toclbox log info "Routing jobs from queue $queue through $route"
        foreach {proc fname} [split $route "@"] break
        
        foreach dir $D2A(-exts) {
            set plugin [file join [toclbox resolve $dir [list appname $::appname]] $fname]
            
            if { [file exists $plugin] && [file type $plugin] eq "file" \
                        && ![dict exists $D2A(plugins) $route] } {
                # Create slave interpreter and give it two commands to interact
                # with us: mqtt to send and debug to output some debugging
                # information.
                set slave [::safe::interpCreate]
                $slave alias disque ::job
                $slave alias debug ::debug $fname
                # Automatically pass further all environment variables that
                # start with the same as the rootname of the plugin
                # implementation.
                ::toclbox::safe::environment $slave [string toupper [file rootname [file tail $plugin]]]*
                # Parse options and relay those into calls to island and/or
                # firewall modules
                foreach {opt value} $options {
                    switch -glob -- [string tolower [string trimleft $opt -]] {
                        "ac*" {
                            # -access enables access to local files or
                            # directories
                            ::toclbox::island::add $slave $value
                        }
                        "al*" {
                            # -allow enables access to remote servers
                            lassign [split $value :] host port
                            ::toclbox::firewall::allow $slave $host $port
                        }
                        "d*" {
                            # -deny refrains access to remote servers
                            lassign [split $value :] host port
                            ::toclbox::firewall::deny $slave $host $port
                        }
                        "p*" {
                            # -package arranges for the plugin to be able to
                            # access a given package.
                            set version ""
                            if { [regexp {:(\d+(\.\d+)*)} $value - version] } {
                                set pkg [regsub {:(\d+(\.\d+)*)} $value ""]
                            } else {
                                set pkg $value
                            }
                            switch -- $pkg {
                                "http" {
                                    toclbox log debug "Helping out package $pkg"
                                    ::toclbox::safe::environment $slave * "" tcl_platform
                                    ::toclbox::safe::alias $slave encoding ::toclbox::safe::invoke $slave encoding
                                }
                            }
                            ::toclbox::safe::package $slave $pkg $version
                        }
                        "e*" {
                            # -environement to pass/set environment variables.
                            set equal [string first "=" $value]
                            if { $equal >= 0 } {
                                set varname [string trim [string range $value 0 [expr {$equal-1}]]]
                                set value [string trim [string range $value [expr {$equal+1}] end]]
                                ::toclbox::safe::envset $slave $varname $value
                            } else {
                                ::toclbox::safe::environment $slave $value
                            }
                        }
                    }
                }
                toclbox log info "Loading plugin at $plugin"
                if { [catch {$slave invokehidden source $plugin} res] == 0 } {
                    # Remember fullpath to plugin, this will be used when data
                    # is coming in to select the slave to send data to. Without
                    # presence of the key in the dictionary, the HTTP receiving
                    # callback will not forward data.
                    dict set D2A(plugins) $route $slave
                    lappend slaves $slave
                } else {
                    toclbox log error "Cannot load plugin at $plugin: $res"
                }
                break;         # First match wins!
            }
        }
    }

    return $slaves
    
}


proc Poll {} {
    global D2A

    foreach { queue route options } $D2A(-routes) {
        set len [$D2A(disque) qlen $queue]
        if { $len > 0 } {
            # Decide number of jobs to get from queue
            if { $len > $D2A(-chunk) } {
                set nbjobs $D2A(-chunk)
            } else {
                set nbjobs $len
            }

            # Get each job from the queue
            toclbox debug DEBUG "Acquiring $nbjobs job(s) from $queue"
            foreach job [$D2A(disque) getjob -nohang -count $nbjobs $queue] {
                lassign $job q jid body

                if { [dict exists $D2A(plugins) $route] } {
                    set slave [dict get $D2A(plugins) $route]
                    if { [interp exists $slave] } {
                        foreach {proc fname} [split $route "@"] break
                        # Isolate procedure name from possible arguments.
                        set call [split $proc !]
                        set proc [lindex $call 0]
                        set args [lrange $call 1 end]
                        # Pass requested URL, headers and POSTed data to the plugin
                        # procedure.
                        if { [catch {$slave eval [linsert $args 0 $proc $queue $jid $body]} res] } {
                            toclbox log warn "Error when calling back $proc: $res"
                        } else {
                            toclbox log debug "Successfully called $proc for $queue: $res"
                        }
                    } else {
                        toclbox log warn "Cannot find slave interp for $route anymore!"
                    }
                } else {
                    toclbox log warn "Cannot find plugin at $fname for $route"
                }

            }
        }
    }

    after $D2A(-poll) ::Poll
}


proc Liveness { d state args } {
    toclbox debug INFO "Connection state is $state: $args"
}

set D2A(disque) [disque -nodes $D2A(-nodes)]

# Read list of recognised plugins out from the routes.  Plugins are only to be
# found in the directory specified as part of the -exts option.  Each file will
# be sourced into a safe interpreter and will be given the commands called
# "debug" and "disque" to be able to operate on the disque queue.
if { [llength [plugin:init $D2A(disque)]] } {
    after $D2A(-poll) ::Poll
    vwait forever
} else {
    toclbox debug WARN "No successfull routing established, aborting"
}

