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
    -verbose    "* INFO"         "Verbosity specification for program and modules"
    -nodes      "localhost:7711" "List of remote Disque servers to connect to"
    -exts       "%prgdir%/exts"  "Path to plugins directory"
    -routes     ""               "Topic routing: default is direct mapping of ALL reqs!"
    -poll       "100"            "Job polling frequency, in ms"
    -chunk      "1"              "Max number of jobs to get from each queue"
    -ackmode    "auto"           "Job acknowledgment mode: auto, manual or boolean"
    -retry      "100:120000"     "Retry connection?"    
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
    disque  ""
    retry   -1
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
toclbox apparmor -allow */bin/echo \
                 -allow */bin/printf \
                 -allow */bin/grep \
                 -allow */bin/sed \
                 -allow */bin/awk \
                 -allow */bin/jq \
                 -allow */bin/cut \
                 -allow */bin/head \
                 -allow */bin/tail \
                 -allow */bin/tr \
                 -allow */bin/sort
toclbox offload D2A(-routes) 3 "routes"
toclbox offload D2A(-nodes) 1 "nodes"


# ::job -- Slave job processing
#
#      This procedure is aliased into the slave interpreters under the command
#      name 'disque'. The queue is automatically passed by construction and it
#      enables slave interpreters to operate on Disque jobs, i.e. acknowledge
#      the jobs, tell the cluster that job is still in process, etc.
#
# Arguments:
#      queue    Name of queue at Disque
#      cmd      Sub-command: ack(nowledge), work(ing), nack
#      id       Job id
#
# Results:
#      None.
#
# Side Effects:
#      Uses the Disque API to clear away jobs, reschedule them, etc.
proc ::job { queue cmd id } {
    global D2A

    set cmd [string tolower $cmd]
    switch -glob -- $cmd {
        "ack*" {
            toclbox debug INFO "Acknowledging job $id in queue $queue"
            $D2A(disque) ackjob $id
        }
        "work*" {
            toclbox debug INFO "Still working on job $id in queue $queue"
            $D2A(disque) working $id
        }
        "nack*" {
            toclbox debug INFO "Giving up on job $id in queue $queue"
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
#       interpreter will be donated commands "debug" and "disque".
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
        lassign [split $route "@"] proc fname
        
        # Use a "!" leading character for the filename as a marker for non-safe
        # interpreters.
        if { [string index $fname 0] eq "!" } {
            set strong 1
            set fname [string range $fname 1 end]
        } else {
            set strong 0
        }
        
        foreach dir $D2A(-exts) {
            set plugin [file join [toclbox resolve $dir [list appname $::appname]] $fname]
            
            if { [file exists $plugin] && [file type $plugin] eq "file" \
                        && ![dict exists $D2A(plugins) $route] } {
                # Arrange to Automatically pass further all environment
                # variables that start with the same as the rootname of the
                # plugin implementation.
                set envptn [string toupper [file rootname [file tail $plugin]]]*
                # Create slave interpreter and give it two commands to interact
                # with us: disque to operate on jobs and debug to output some
                # debugging information.
                if { $strong } {
                    set slave [::toclbox::interp::create $plugin \
                                        -environment $envptn \
                                        -alias [list disque ::job $queue] \
                                        -alias [list debug ::debug $fname] \
                                        {*}$options]
                } else {
                    set slave [::toclbox::interp::create $plugin \
                                        -safe \
                                        -environment $envptn \
                                        -alias [list disque ::job $queue] \
                                        -alias [list debug ::debug $fname] \
                                        {*}$options]
                }
                if { $slave ne "" } {
                    dict set D2A(plugins) $route $slave
                    lappend slaves $slave
                }
                break;         # First match wins!
            }
        }
    }

    return $slaves    
}


# Poll -- Periodical queue polling
#
#      Periodically polls all queues for possible jobs by chunks. Polling is
#      non-blocking.  Automatically acknowledge or reject jobs depending on the
#      boolean returned by the bound procedure when in -ackmode is set to auto.
#
# Arguments:
#      None.
#
# Results:
#      None.
#
# Side Effects:
#      Poll the queue for jobs and automatically ack or nack the jobs when
#      relevant
proc Poll {} {
    global D2A

    if { $D2A(disque) ne "" } {
        foreach { queue route options } $D2A(-routes) {
            # Get each job from the queue
            toclbox debug DEBUG "Trying to acquire $D2A(-chunk) job(s) from $queue"
            if { [catch {$D2A(disque) getjob -nohang -count $D2A(-chunk) $queue} jlist] == 0 } {
                foreach job $jlist {
                    lassign $job q jid body

                    toclbox debug INFO "Attempting to route and ingest job $jid from queue $queue"
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
                                toclbox log debug "Successfully called $proc for queue $queue: $res"
                                # Acknowledge or reject job depending on the result of
                                # the procedure. When in auto mode, we check that the
                                # job still exists before we even look at the result.
                                if { $D2A(-ackmode) in [list "auto" "boolean"] } {
                                    if { $D2A(-ackmode) eq "boolean" || [llength [$D2A(disque) show $jid]] } {
                                        if { [string is boolean -strict $res] } {
                                            job $queue [expr {$res?"ack":"nack"}] $jid
                                        } else {
                                            toclbox debug WARN "'$res' is not a boolean, return a boolean\
                                                                or use the 'disque' command from your script!"
                                        }
                                    }
                                }
                            }
                        } else {
                            toclbox log warn "Cannot find slave interp for $route anymore!"
                        }
                    } else {
                        toclbox log warn "Cannot find plugin at $fname for $route"
                    }
                }
            } else {
                # Force disconnection, any jobs will stay at the server(s) and
                # we will try to reconnect if relevant for the command line
                # arguments.
                toclbox debug WARN "Could not get job list: $jlist"
                Disconnect
            }
        }
    }

    after $D2A(-poll) ::Poll
}


# Liveness -- Connection liveness
#
#      Print liveness of connection
#
# Arguments:
#      d        Identifier of connection to Disque
#      state    State of connection
#      args     Additional arguments depending on state
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc Liveness { d state args } {
    global D2A

    # Debug output
    if { [string toupper $state] ne "COMMAND" } {
        if { [llength $args] } {
            toclbox debug INFO "Connection state is $state: $args"
        } else {
            toclbox debug INFO "Connection state is $state"
        }
    }

    # Take care of connection state. This arranges to reset the (re)connection
    # exponential backoff timer to its initial state as soon as we've had
    # success connecting to the server.
    switch -- [string toupper $state] {
        "CONNECTED" {
            set D2A(retry) [NextConnect 1]
        }
        "CLOSE" {
        }
    }
}


proc ::Disconnect {} {
    global D2A

    if { $D2A(disque) ne "" } {
        if { [catch {$D2A(disque) close} err] == 0 } {
            toclbox debug NOTICE "Close connection to Disque server"
        } else {
            toclbox debug WARN "Error when closing connection to Disque server: $err"
        }
    }
    set D2A(disque) ""
}


proc ::Connect { { force 0 } } {
    global D2A

    # Force disconnection
    if { $force } {
        Disconnect
    }

    # Try to connect and keep state in global array
    if { $D2A(disque) eq "" } {
        toclbox debug NOTICE "Connecting to one of the Disque server at $D2A(-nodes)"
        if { [catch {disque -nodes $D2A(-nodes) -liveness ::Liveness} d] == 0 } {
            set D2A(disque) $d
        } else {
            toclbox debug WARN "Could not connect! $d"
        }
    }

    # Decide when to try with connection next time, the logic is that we won't
    # try to connect if we already have a connection, meaning that we can have
    # the timer going all the time if necessary.
    set when -1
    if { $D2A(disque) eq "" } {
        set when [NextConnect]
        if { $when >= 0 } {
            toclbox debug INFO "New connection attempt in $when ms."
        }
    } else {
        set when $D2A(retry)
    }

    # Perform connection check only if we should.
    if { $when >= 0 } {
        after $when [list ::Connect]
    }

    return $D2A(disque)
}

proc NextConnect { { force 0 } } {
    global D2A

    # Force reconnection backoff timer (re)initialisation.
    if { $force } {
        set D2A(retry) -1
    }

    # Try to connect again to the server in a little while, this
    # will arrange to force the creation of a whole new MQTT
    # context and connection. The current implementation is able
    # of exponential backoff to minimise the strain on the broker
    if { [string first ":" $D2A(-retry)] >= 0 } {
        # Use the colon sign to express the minimum time to wait
        # for reconnection, the maximum and the factor by which
        # to multiply each time (defaults to twice)
        lassign [split $D2A(-retry) ":"] min max factor
        if { $factor eq "" } { set factor 2 }
        set D2A(retry) [expr {int($D2A(retry)*$factor)}]
        if { $D2A(retry) < 0 } {
            set D2A(retry) $min
        } elseif { $D2A(retry) > $max } {
            set D2A(retry) $max
        }
    } else {
        # Otherwise -retry should just be an integer. Covers for
        # most mistakes (non-integer, empty string) through
        # turning the feature off.
        set D2A(retry) $D2A(-retry)
        if { $D2A(retry) eq "" \
                    || ![string is integer -strict $D2A(retry)] } {
            toclbox debug WARN "$D2A(-retry) should be an integer or integers separated by colon signs!"
            set D2A(retry) -1
        }
    }

    return $D2A(retry)
}

# Open connection to one of the servers and keep trying to connect to the
# servers whenever the connection isn't alive.
Connect

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
