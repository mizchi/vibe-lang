export let recv = (channel: Int) -> String {
  threads_recv(channel)
}
export let send = (channel: Int, message: String) -> Bool {
  threads_send(channel, message)
}
export let wait = (task: Int) -> Int {
  threads_wait(task)
}
export let spawn = (name: String, mailbox: Int) -> Int {
  threads_spawn(name, mailbox)
}
export let probe_wat = () -> String {
  threads_probe_wat()
}
export let channel_new = (capacity: Int) -> Int {
  threads_channel_new(capacity)
}
export let runtime_hints = () {
  threads_runtime_hints()
}
