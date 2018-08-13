proc print { queue id body } {
    debug "Job received with id: $id on queue: $queue\n\t$body"
    # Both acknowledge the job and return true, which will lead to proper
    # acknowledge in most modes.
    disque ack $id
    return 1
}