# SIGCHLD bridge fun spliced into the user prelude. Not `require`d
# directly; sigchld_bridge.cr reads it via `{{ read_file }}`. Depends on
# `Crystal::System::SignalChildHandler.notify_reaped`, which the prelude
# provides at splice time.

fun crystal_jit_notify_reaped(pid : LibC::PidT, exit_code : Int32) : Bool
  Crystal::System::SignalChildHandler.notify_reaped(pid, exit_code)
end
