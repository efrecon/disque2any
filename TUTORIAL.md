# Tutorial

This document provides quick instructions to exercise `disque2any`
interactively. This tutorial supposes that you will be able to run Docker
containers as your primary user to quickly get a Disque queue running. The
instructions can easily be adapting if you have a running Disque server
installed differently or elsewhere.

## Create a Disque Server

Run the following command to quickly create a Disque server. This uses a Docker
Disque [image](https://hub.docker.com/r/efrecon/disque/)

    $ docker run -it --rm --name disque efrecon/disque:1.0-rc1

## Create a Job and a Test Queue

Once the Disque container is running, and from another prompt, run the following
command. The command runs, in the container created above and called `disque`,
the `disque` binary.  This binary, within the container, will connect to the
`disque` server running locally and execute the Disque command called `ADDJOB`
to create a job in the queue called `test`.

    $ docker exec -it disque disque ADDJOB test "this is  a test" 5000

## Pull and Print Job

From the same prompt (or another), run the following command to discover the IP
address of the container running the Disque server and store the address in a
variable:

    DISQUE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' disque)

Once done, run the following command from this very directory. The command uses
an example job routing ingestion procedure that simply print out jobs and
arrange for `disque2any` to acknowledge the jobs once they have been printed out
on the console. The command binds this procedure, found in
[printer.tcl](printer.tcl), to the `test` queue to which a job was posted in the
previous section:

    $ ./disque2any.tcl -nodes $DISQUE_IP:7711 -routes "test print@printer.tcl \"\""

This command should output something similar to the following lines and you
should recognise the identifier of the job that was output by the `ADDJOB`
command in the previous section.

```
[20180821 221058] [info] [disque2any] Routing jobs from queue test through print@printer.tcl
[20180821 221058] [notice] [safe] Selectively passing keys matching PRINTER* (but not ) from global env
[20180821 221058] [info] [interp] Sourcing content of /home/emmanuel/dev/projects/scott/disque2any/exts/printer.tcl
[20180821 221058] [info] [disque2any] Attempting to route and ingest job D-f2f665e5-AMeLi/0bW74qqr+8vCE5+VS7-05a1 from queue test
[20180821 221058] [info] [disque2any] Acknowledging job D-f2f665e5-AMeLi/0bW74qqr+8vCE5+VS7-05a1 in queue test
```