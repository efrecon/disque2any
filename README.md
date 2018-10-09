# disque2any

This program implements a generic [Disque](https://github.com/antirez/disque)
job ingester. It accepts a number of routes that will pass job bodies acquired
from specified queues to sandboxed [Tcl](https://www.tcl.tk/)
[interpreters](https://www.tcl.tk/man/tcl8.6/TclCmd/safe.htm) for ingestion and
treatment. The sandboxing is able to restrict which part of the disk hierarchy
is accessible to the interpreters, and which hosts these interpreters are
allowed to communicate with. This manual describes command-line options and the
interaction between the job queues and ingesting procedures. For a quick
tutorial, consult [this](TUTORIAL.md) document instead.

## Command-Line Options

The program only accepts single-dash led full options on the command-line.
The complete list of recognised options can be found below:

- `-nodes` is a space-separated list of nodes to connect to within the Disque
  cluster. Each specification is of the form `<password>@<hostname>:<port>`
  where the password and port number can be omitted. Connection will be
  establish to one of the host at random. The default is to attempt connection
  to `localhost` only.
  
- `-exts` is a whitespace separated list of directory specifications where to
  look for plugins.
  
- `-routes` is a list of triplets describing the routes for data transformation
  depending on incoming paths. The first item is a queue, the second item a
  specification for how to transform data (see below) and the third item is a
  list of dash-led options and their values (see below).
  
- `-poll` is the number of milliseconds between polling the queues at the server
  for possible job availability, it defaults to `100`.
  
- `-chunk` is the maximium number of jobs to get from one queue at a time, it
  defaults to `1`.

- `-ackmode` can be one of `auto` (the default), `manual` or `boolean`. It
  describes how procedures bound to job queues reception interact with the main
  program for acknowledging (or rejecting) jobs. See below.

### Offloading Values

For the command-line options `-routes` and `-nodes`, it is possible to offload
the value from a file or the result of a command. Whenever the value starts with
a `@` sign, the remaining characters should form a path to a file where the
content of the option will be taken from. Whenever the value starts with a `!`
sign, the remaining characters should form a command to execute to get the
content of the option. Both facilities makes it easier to load the value of
these options as they might be long to enter directly at the command-line or
need improved secrecy, such as, for example, when used in association with
Docker [secrets]. For security reasons, only a restricted set of commands is
allowed in the pipelines following the `!` sign. At the time of writing, these
are targetting easy textual extractions from files: `echo`, `printf`, `grep`,
`sed`, `awk`, `jq`, `cut`, `head`, `tail` and `sort`. There is no way to
configure this list as it would provide a workaround to this security measure.

  [secrets]: https://docs.docker.com/engine/swarm/secrets


## Routing

Through its `-routes` command-line option, you will be able to bind procedures
to a specific queue. The name of the queue, the job identifier and its body are
always passed as arguments to the procedures and these will be able to operate
on the body before acknowledging the job. You will also be able to pass
arguments to those procedures in order to refine what they should perform or
which topic they should send to, for example. Job ingestion occuring in plugins
will be executed within safe Tcl interpreters, which guarantees maximum
flexibility when it comes to transformation capabilities while guaranteeing
security through encapsulation of all IO and system commands.

All `tcl` files implementing the plugins should be placed in the directories
that is pointed at by the `-exts` option. Binding between queue and procedures
occurs through the `-routes` option. For example, starting the program with
`-routes "test print@printer.tcl \"\""` will arrange for all jobs available at
the queue `test` to be routed towards the procedure `print` that can be found in
the file `printer.tcl`. Whenever a job is available, the procedure will be
called with the following arguments.

1. The queue name.

2. The identifier of the job.

3. The job body.

The procedure `print` is then free to perform any kind of operations it deems
necessary on the job data. An example `print` procedure is availabe under the
`exts` subdirectory in the `printer.tcl` file. The procedure will print the
content of each job received on the queue and automatically acknowledge it.

### Interacting with Jobs

When `-ackmode` is `manual` and once all ingestion has succeeded, the code of
the procedure can mark the job as done using the `disque` command.  That command
is automatically bound to the queue and will look similar to the following
pseudo code:

    disque ack $id

The `disque` command accepts a number of sub-commands to operate on jobs, these
are:

- `ack` to acknowledge the job.

- `nack` to mark the job as not treated.

- `working` to mediate the cluster that the job still is being worked on.

When `-ackmode` is `boolean`, the procedure should return a boolean. When this
boolean is true, the job will be acknowledge, otherwise it will be rejected.
When `-ackmode` is auto, the behaviour is almost identical to `boolean`, but the
return value will only be checked if the job still exists.

### Additional Arguments

To pass arguments to the procedure, you can separate them with `!`-signs after
the name of the procedure.  These arguments will be blindly passed after the
requested URL and the data to the procedure when it is executed.  So, for
example, if your route contained a plugin specification similar to
`myproc!onearg!3@myplugin.tcl`, procedure `myproc` in `myplugin.tcl` would be
called with five arguments everytime a job is available, i.e. the queue, the job
id, the content of the job and `onearg` and `3` as arguments.  Spaces are
allowed in arguments, as long as you specify quotes (or curly-braces) around the
procedure call construct.

### Escaping Safe Interpreters

Every route will be executed in a safe interpreter, meaning that it will have a
number of heavy restriction as to how the interpreter is able to interoperate
with its environment and external resources. When specifying routes, the last
item of each routing specification triplet is a list of dash-led options
followed by values, options that can be used to tame the behaviour of the
interpreter and selectively let it access external resources of various sorts.
These options can appear as many times as necessary and are understood as
follows:

- `-access` will allow the interpreter to access a given file or directory on
  disk. The interpreter will be able to both read and write to that location.

- `-allow` takes a host pattern and a port as a value, separated by a colon.
  This allows the interpreter to access hosts matching that pattern with the
  [socket] command.

- `-deny` takes the same form as `-allow`, but will deny access to the host
  (pattern) and port. Allowance and denial rules are taken in order, so `-deny`
  can be used to selectively deny to some of the hosts that would otherwise have
  had been permitted using `-allow`.

- `-package` takes the name of a package, possibly followed by a colon and a
  version number as a value. It will arrange for the interpreter to load that
  package (at that version number).

- `-environment` takes either an environment variable or a variable and its
  value. When followed by the name of a variable followed by an equal `=` sign
  and a value, this will set the environment variable to that value in the
  interpreter. When followed by just the name of an environment variable, it
  will arrange to pass the variable (and its value) to the safe interpreter.

  [socket]: https://www.tcl.tk/man/tcl/TclCmd/socket.htm

- `-retry` describes what this program should be done when disconnected from a
  Disque server node. Whenever this is an integer less than 0, no reconnection
  will be attempted. Otherwise the value of this option should be an integer
  number of milliseconds expressing the period at which reconnection attempts
  will be made. The value of this option can also be up to three integers
  separated by the colon `:` sign, to implement an exponential backoff for
  reconnection. The first integer is the minimal number of milliseconds to wait
  before reconnecting. The second integer the maximum number of milliseconds to
  wait and the last the factor by which to multiply the previous period at each
  unsuccessfull reconnection attempt (defaults to `2`).

#### Strong Interpreters

Whenever the name of the file from which the interpreter is to be created starts
with an exclamation mark (`!`), the sign will be removed from the name when
looking for the implementation and the interpreter will be a regular (non-safe)
interpreter. This allows for more powerful interpreters, or to make use of
packages that have no support for the safe base.

Creating non-safe interpreters is not the preferred way of interacting with
external code. It should only be used in controlled and trusted environments.
Otherwise, `disque2any` is tuned for working with code in sandboxed interpreters
and the additional security that safe interpreters provide.

## Docker

A Docker [image](https://hub.docker.com/r/efrecon/disque2any/) is provided. The
image builds upon [efrecon/medium-tcl] in order to provide a rather complete
Tcl-programming environment for running Disque ingestion scripts. In order to
provide your own scripts, easiest is to make them available under the
`/var/disque2any/exts` directory of containers based on this image.

  [efrecon/medium-tcl]: https://hub.docker.com/r/efrecon/medium-tcl/