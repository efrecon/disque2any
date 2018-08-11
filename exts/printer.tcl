proc print { queue id body } {
    debug "Job received with id: $id on queue: $queue\n\t$body"
    disque ack $id
}