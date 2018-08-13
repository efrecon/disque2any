FROM efrecon/medium-tcl
MAINTAINER Emmanuel Frecon <efrecon@gmail.com>

COPY *.tcl /opt/disque2any/
COPY lib/disque/ /opt/disque2any/lib/disque/
COPY lib/toclbox/ /opt/disque2any/lib/toclbox/

# Export the plugin directory so it gets easy to test new plugins.
VOLUME /opt/disque2any/exts

ENTRYPOINT ["tclsh8.6", "/opt/disque2any/disque2any.tcl"]